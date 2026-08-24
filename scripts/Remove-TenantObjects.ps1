[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [switch] $DeleteObjectsCreatedByThisEnvironment
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Cleanup.Guards.psm1" -Force
Import-Module "$PSScriptRoot\Tenant.Guards.psm1" -Force
Import-Module "$PSScriptRoot\EmergencyAccess.GraphAuthentication.psm1" -Force
Import-Module "$PSScriptRoot\..\src\functions\shared\EmergencyAccess.Remediation.psm1" -Force
Assert-AzdTenantContext
if (-not $DeleteObjectsCreatedByThisEnvironment) {
    throw 'Use -DeleteObjectsCreatedByThisEnvironment to acknowledge tenant-object deletion.'
}

$requiredScopes = @(
    'User.ReadWrite.All',
    'Group.ReadWrite.All',
    'AdministrativeUnit.ReadWrite.All',
    'Policy.ReadWrite.ConditionalAccess'
)
$allowInteractiveGraph = -not (
    $env:CI -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected
)
Connect-EmergencyAccessGraph `
    -Scopes $requiredScopes `
    -ProbeUri '/v1.0/users?$top=1&$select=id' `
    -AllowInteractive:$allowInteractiveGraph `
    -AllowContextReplacement:$allowInteractiveGraph | Out-Null
$context = Get-MgContext
$missingScopes = @()
if ($env:AZD_OWNED_EMERGENCY_GROUP_ID -and
    'Policy.Read.AuthenticationMethod' -notin $context.Scopes -and
    'Policy.ReadWrite.AuthenticationMethod' -notin $context.Scopes) {
    $missingScopes += 'Policy.Read.AuthenticationMethod (or Policy.ReadWrite.AuthenticationMethod)'
}
if ($missingScopes.Count -gt 0) {
    throw "The proven Microsoft Graph context is missing cleanup scopes: $($missingScopes -join ', '). Refresh the normal cached/browser context, then retry."
}

function Invoke-CleanupGraphRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'PATCH')]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Uri,
        [string] $Body
    )

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $parameters = @{
                Method = $Method
                Uri = $Uri
            }
            if ($Body) {
                $parameters.Body = $Body
                $parameters.ContentType = 'application/json'
            }
            return Invoke-MgGraphRequest @parameters
        }
        catch {
            $responseProperty = $_.Exception.PSObject.Properties['Response']
            $response = if ($responseProperty) { $responseProperty.Value } else { $null }
            $statusCode = if ($response -and $response.StatusCode) {
                [int]$response.StatusCode
            }
            elseif ($_.Exception.Message -match 'HTTP\s+(429|503)') {
                [int]$Matches[1]
            }
            else {
                0
            }
            if ($statusCode -notin 429, 503 -or $attempt -eq 4) {
                throw
            }

            $delaySeconds = [math]::Pow(2, $attempt - 1)
            $retryAfter = if ($response -and $response.Headers) { $response.Headers.RetryAfter } else { $null }
            if ($retryAfter -and $retryAfter.Delta) {
                $delaySeconds = [math]::Ceiling($retryAfter.Delta.TotalSeconds)
            }
            elseif ($retryAfter -and $retryAfter.Date) {
                $delaySeconds = [math]::Ceiling(($retryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds)
            }
            Start-Sleep -Seconds ([math]::Max(1, [math]::Min(30, $delaySeconds)))
        }
    }
}

function Remove-ConditionalAccessGroupReferences {
    param(
        [Parameter(Mandatory)][string] $GroupId,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]] $ChangedPolicyIds
    )

    $nextLink = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
    while ($nextLink) {
        $page = Invoke-CleanupGraphRequest -Method GET -Uri $nextLink
        foreach ($policy in @($page.value)) {
            $excludeGroups = @($policy.conditions.users.excludeGroups) | Where-Object { $_ }
            if ($GroupId -notin $excludeGroups) {
                continue
            }

            $policyId = [string]$policy.id
            $policyUri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$policyId"
            $freshPolicy = Invoke-CleanupGraphRequest -Method GET -Uri $policyUri
            $freshExcludeGroups = @(
                $freshPolicy.conditions.users.excludeGroups |
                    Where-Object { $_ } |
                    ForEach-Object { [string]$_ } |
                    Select-Object -Unique
            )
            if ($GroupId -notin $freshExcludeGroups) {
                continue
            }

            $remainingGroups = @($freshExcludeGroups | Where-Object { $_ -ne $GroupId })
            $body = @{
                conditions = @{
                    users = @{
                        excludeGroups = $remainingGroups
                    }
                }
            } | ConvertTo-Json -Depth 6 -Compress
            if ($policyId -notin $ChangedPolicyIds) {
                # Record intent before PATCH so an ambiguous transport failure is also rolled back.
                $ChangedPolicyIds.Add($policyId)
            }
            Invoke-CleanupGraphRequest -Method PATCH -Uri $policyUri -Body $body | Out-Null
            $verifiedPolicy = Invoke-CleanupGraphRequest -Method GET -Uri $policyUri
            if ($GroupId -in @($verifiedPolicy.conditions.users.excludeGroups)) {
                throw "Conditional Access policy '$policyId' still contains the emergency group after cleanup PATCH."
            }
        }
        $nextLinkProperty = $page.PSObject.Properties['@odata.nextLink']
        $nextLink = if ($nextLinkProperty) { [string]$nextLinkProperty.Value } else { '' }
    }
}

function Restore-ConditionalAccessGroupReference {
    param(
        [Parameter(Mandatory)][string] $GroupId,
        [Parameter(Mandatory)][string] $PolicyId
    )

    $policyUri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$PolicyId"
    $freshPolicy = Invoke-CleanupGraphRequest -Method GET -Uri $policyUri
    $currentGroups = @(
        $freshPolicy.conditions.users.excludeGroups |
            Where-Object { $_ } |
            ForEach-Object { [string]$_ } |
            Select-Object -Unique
    )
    if ($GroupId -in $currentGroups) {
        return
    }
    if ('None' -notin @($freshPolicy.conditions.users.includeUsers)) {
        Invoke-EmergencyAccessRemediation `
            -EmergencyAccountsGroupObjectId $GroupId `
            -CAPolicyId $PolicyId `
            -SkipManagedIdentityConnection | Out-Null
        return
    }

    # The shared remediation deliberately skips policies that target no users. Cleanup
    # still restores their exact prior reference so a failed deletion is fully reversible.
    $body = @{
        conditions = @{
            users = @{
                excludeGroups = @($currentGroups + $GroupId)
            }
        }
    } | ConvertTo-Json -Depth 6 -Compress
    Invoke-CleanupGraphRequest -Method PATCH -Uri $policyUri -Body $body | Out-Null
    $verifiedPolicy = Invoke-CleanupGraphRequest -Method GET -Uri $policyUri
    if ($GroupId -notin @($verifiedPolicy.conditions.users.excludeGroups)) {
        throw "Conditional Access policy '$PolicyId' did not contain the emergency group after rollback PATCH."
    }
}

function Remove-TapGroupReference {
    param(
        [Parameter(Mandatory)][string] $GroupId,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $ChangedTargets
    )

    $path = 'https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass'
    $configuration = Invoke-CleanupGraphRequest -Method GET -Uri $path
    $removedTarget = @($configuration.includeTargets) | Where-Object { $_.id -eq $GroupId } | Select-Object -First 1
    if (-not $removedTarget) {
        return
    }
    if ('Policy.ReadWrite.AuthenticationMethod' -notin $context.Scopes) {
        throw 'The owned emergency group is still targeted by the Temporary Access Pass policy, but the proven Microsoft Graph context lacks Policy.ReadWrite.AuthenticationMethod. Refresh the normal cached/browser context, then retry cleanup.'
    }
    $remainingTargets = @($configuration.includeTargets) | Where-Object { $_.id -ne $GroupId }
    # Record intent before PATCH so an ambiguous transport failure is also rolled back.
    $ChangedTargets.Add($removedTarget)
    $body = @{
        '@odata.type' = '#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration'
        state = $configuration.state
        includeTargets = $remainingTargets
    } | ConvertTo-Json -Depth 8 -Compress
    Invoke-CleanupGraphRequest -Method PATCH -Uri $path -Body $body | Out-Null
    $verifiedConfiguration = Invoke-CleanupGraphRequest -Method GET -Uri $path
    if ($GroupId -in @($verifiedConfiguration.includeTargets.id)) {
        throw 'The Temporary Access Pass policy still contains the emergency group after cleanup PATCH.'
    }
}

function Restore-TapGroupReference {
    param([Parameter(Mandatory)][object] $Target)

    $path = 'https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass'
    $configuration = Invoke-CleanupGraphRequest -Method GET -Uri $path
    if ([string]$Target.id -in @($configuration.includeTargets.id)) {
        return
    }
    $body = @{
        '@odata.type' = '#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration'
        state = $configuration.state
        includeTargets = @(@($configuration.includeTargets) + $Target)
    } | ConvertTo-Json -Depth 8 -Compress
    Invoke-CleanupGraphRequest -Method PATCH -Uri $path -Body $body | Out-Null
    $verifiedConfiguration = Invoke-CleanupGraphRequest -Method GET -Uri $path
    if ([string]$Target.id -notin @($verifiedConfiguration.includeTargets.id)) {
        throw 'The Temporary Access Pass policy did not contain the emergency group after rollback PATCH.'
    }
}

$objects = @(
    @{
        Ownership = 'AZD_OWNED_ADMINISTRATIVE_UNIT_ID'
        CurrentName = 'AZD_ADMINISTRATIVE_UNIT_ID'
        CurrentId = $env:AZD_ADMINISTRATIVE_UNIT_ID
        OwnedId = $env:AZD_OWNED_ADMINISTRATIVE_UNIT_ID
        Uri = 'https://graph.microsoft.com/v1.0/directory/administrativeUnits'
    },
    @{
        Ownership = 'AZD_OWNED_EMERGENCY_GROUP_ID'
        CurrentName = 'AZD_EMERGENCY_GROUP_ID'
        CurrentId = $env:AZD_EMERGENCY_GROUP_ID
        OwnedId = $env:AZD_OWNED_EMERGENCY_GROUP_ID
        Uri = 'https://graph.microsoft.com/v1.0/groups'
    },
    @{
        Ownership = 'AZD_OWNED_EMERGENCY_USER1_ID'
        CurrentName = 'AZD_EMERGENCY_USER1_ID'
        UpnName = 'AZD_EMERGENCY_USER1_UPN'
        CurrentId = $env:AZD_EMERGENCY_USER1_ID
        OwnedId = $env:AZD_OWNED_EMERGENCY_USER1_ID
        Uri = 'https://graph.microsoft.com/v1.0/users'
    },
    @{
        Ownership = 'AZD_OWNED_EMERGENCY_USER2_ID'
        CurrentName = 'AZD_EMERGENCY_USER2_ID'
        UpnName = 'AZD_EMERGENCY_USER2_UPN'
        CurrentId = $env:AZD_EMERGENCY_USER2_ID
        OwnedId = $env:AZD_OWNED_EMERGENCY_USER2_ID
        Uri = 'https://graph.microsoft.com/v1.0/users'
    },
    @{
        Ownership = 'AZD_OWNED_EMERGENCY_USER3_ID'
        CurrentName = 'AZD_EMERGENCY_USER3_ID'
        UpnName = 'AZD_EMERGENCY_USER3_UPN'
        CurrentId = $env:AZD_EMERGENCY_USER3_ID
        OwnedId = $env:AZD_OWNED_EMERGENCY_USER3_ID
        Uri = 'https://graph.microsoft.com/v1.0/users'
    }
)

foreach ($object in $objects) {
    if (Test-OwnedObjectId -CurrentId $object.CurrentId -OwnedId $object.OwnedId) {
        if ($PSCmdlet.ShouldProcess($object.OwnedId, "Delete object recorded by $($object.Ownership)")) {
            $changedConditionalAccessPolicies = [Collections.Generic.List[string]]::new()
            $changedTapTargets = [Collections.Generic.List[object]]::new()
            try {
                if ($object.Ownership -eq 'AZD_OWNED_EMERGENCY_GROUP_ID') {
                    Remove-ConditionalAccessGroupReferences `
                        -GroupId $object.OwnedId `
                        -ChangedPolicyIds $changedConditionalAccessPolicies
                    Remove-TapGroupReference `
                        -GroupId $object.OwnedId `
                        -ChangedTargets $changedTapTargets
                }
                Invoke-MgGraphRequest -Method DELETE -Uri "$($object.Uri)/$($object.OwnedId)"
            }
            catch {
                $deletionError = $_
                if ($object.Ownership -ne 'AZD_OWNED_EMERGENCY_GROUP_ID') {
                    throw
                }

                $groupState = 'unknown'
                $verificationErrors = [Collections.Generic.List[string]]::new()
                for ($attempt = 1; $attempt -le 4 -and $groupState -eq 'unknown'; $attempt++) {
                    try {
                        Invoke-MgGraphRequest -Method GET -Uri "$($object.Uri)/$($object.OwnedId)?`$select=id" | Out-Null
                        $groupState = 'exists'
                    }
                    catch {
                        if ($_.Exception.Message -match 'HTTP 404|Request_ResourceNotFound') {
                            $groupState = 'deleted'
                        }
                        else {
                            $verificationErrors.Add($_.Exception.Message)
                            if ($attempt -lt 4) {
                                Start-Sleep -Seconds ([math]::Pow(2, $attempt - 1))
                            }
                        }
                    }
                }

                if ($groupState -ne 'deleted') {
                    $restoreErrors = [Collections.Generic.List[string]]::new()
                    foreach ($policyId in $changedConditionalAccessPolicies) {
                        try {
                            Restore-ConditionalAccessGroupReference `
                                -GroupId $object.OwnedId `
                                -PolicyId $policyId
                        }
                        catch {
                            $restoreErrors.Add("$policyId`: $($_.Exception.Message)")
                        }
                    }
                    foreach ($tapTarget in $changedTapTargets) {
                        try {
                            Restore-TapGroupReference -Target $tapTarget
                        }
                        catch {
                            $restoreErrors.Add("Temporary Access Pass policy: $($_.Exception.Message)")
                        }
                    }
                    if ($restoreErrors.Count -gt 0) {
                        $stateDetail = if ($groupState -eq 'unknown') {
                            " State verification also failed: $($verificationErrors -join '; ')."
                        }
                        else {
                            ''
                        }
                        throw "Emergency group cleanup failed and security-policy rollback was incomplete. Operation: $($deletionError.Exception.Message)$stateDetail Rollback: $($restoreErrors -join '; ')"
                    }
                    $stateDetail = if ($groupState -eq 'unknown') {
                        ' Group existence could not be confirmed after four attempts; rollback was attempted for every recorded policy change.'
                    }
                    else {
                        ' All removed Conditional Access exclusions were restored, along with Temporary Access Pass targets.'
                    }
                    throw "Emergency group cleanup failed.$stateDetail $($deletionError.Exception.Message)"
                }
            }
            & azd env set $object.Ownership '' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to clear $($object.Ownership)." }
            & azd env set $object.CurrentName '' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to clear $($object.CurrentName)." }
            if ($object.Ownership -eq 'AZD_OWNED_EMERGENCY_GROUP_ID') {
                foreach ($groupStateName in @(
                    'AZD_ADOPTED_EMERGENCY_GROUP_ID',
                    'AZD_ADOPTED_EMERGENCY_GROUP_MEMBERSHIP_HASH',
                    'AZD_EMERGENCY_GROUP_MEMBER_COUNT'
                )) {
                    & azd env set $groupStateName '' | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Unable to clear $groupStateName." }
                }
            }
            if ($object.Ownership -match '^AZD_OWNED_EMERGENCY_USER[123]_ID$') {
                foreach ($onboardingStateName in @(
                    'AZD_ONBOARDED_EMERGENCY_USER_IDS',
                    'AZD_SECURITY_KEY_DRILL_FINGERPRINT'
                )) {
                    & azd env set $onboardingStateName '' | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Unable to clear $onboardingStateName." }
                }
            }
            if ($object.UpnName) {
                & azd env set $object.UpnName '' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Unable to clear $($object.UpnName)." }
            }
        }
    }
    elseif ($object.OwnedId) {
        Write-Warning "Skipped $($object.Ownership): its exact owned ID does not match the current configured object ID."
    }
}
