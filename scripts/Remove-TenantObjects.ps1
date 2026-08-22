[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [switch] $DeleteObjectsCreatedByThisEnvironment
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Cleanup.Guards.psm1" -Force
Import-Module "$PSScriptRoot\Tenant.Guards.psm1" -Force
Import-Module "$PSScriptRoot\..\src\functions\shared\EmergencyAccess.Remediation.psm1" -Force
Assert-AzdTenantContext
if (-not $DeleteObjectsCreatedByThisEnvironment) {
    throw 'Use -DeleteObjectsCreatedByThisEnvironment to acknowledge tenant-object deletion.'
}

try {
    Connect-MgGraph -NoWelcome | Out-Null
}
catch {
    throw "Unable to authenticate to Microsoft Graph with the standard cached/WAM/browser flow. $($_.Exception.Message)"
}
$context = Get-MgContext
if (-not $context -or $context.TenantId -ne $env:AZURE_TENANT_ID) {
    throw "Microsoft Graph tenant context mismatch. Expected '$($env:AZURE_TENANT_ID)', received '$($context.TenantId)'."
}
$requiredScopes = @(
    'User.ReadWrite.All',
    'Group.ReadWrite.All',
    'AdministrativeUnit.ReadWrite.All',
    'Policy.ReadWrite.ConditionalAccess'
)
if ($env:AZD_ENABLE_TAP_POLICY -eq 'true') {
    $requiredScopes += 'Policy.ReadWrite.AuthenticationMethod'
}
$missingScopes = @($requiredScopes | Where-Object { $_ -notin $context.Scopes })
if ($missingScopes.Count -gt 0) {
    throw "The cached Microsoft Graph context is missing cleanup scopes: $($missingScopes -join ', '). Run the documented one-time Connect-MgGraph initialization, then retry."
}
function Remove-ConditionalAccessGroupReferences {
    param(
        [Parameter(Mandatory)][string] $GroupId,
        [Parameter(Mandatory)][Collections.Generic.List[string]] $ChangedPolicyIds
    )

    $nextLink = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
    while ($nextLink) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $nextLink
        foreach ($policy in @($page.value)) {
            $excludeGroups = @($policy.conditions.users.excludeGroups) | Where-Object { $_ }
            if ($GroupId -notin $excludeGroups) {
                continue
            }

            $remainingGroups = @($excludeGroups | Where-Object { $_ -ne $GroupId } | Select-Object -Unique)
            $body = @{
                conditions = @{
                    users = @{
                        excludeGroups = $remainingGroups
                    }
                }
            } | ConvertTo-Json -Depth 6 -Compress
            Invoke-MgGraphRequest `
                -Method PATCH `
                -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$($policy.id)" `
                -ContentType 'application/json' `
                -Body $body | Out-Null
            $ChangedPolicyIds.Add([string]$policy.id)
        }
        $nextLinkProperty = $page.PSObject.Properties['@odata.nextLink']
        $nextLink = if ($nextLinkProperty) { [string]$nextLinkProperty.Value } else { '' }
    }
}

function Remove-TapGroupReference {
    param([Parameter(Mandatory)][string] $GroupId)

    if ($env:AZD_ENABLE_TAP_POLICY -ne 'true') {
        return
    }
    $path = 'https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass'
    $configuration = Invoke-MgGraphRequest -Method GET -Uri $path
    $remainingTargets = @($configuration.includeTargets) | Where-Object { $_.id -ne $GroupId }
    if ($remainingTargets.Count -eq @($configuration.includeTargets).Count) {
        return
    }
    $body = @{
        '@odata.type' = '#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration'
        state = $configuration.state
        includeTargets = $remainingTargets
    } | ConvertTo-Json -Depth 8 -Compress
    Invoke-MgGraphRequest -Method PATCH -Uri $path -ContentType 'application/json' -Body $body | Out-Null
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
            try {
                if ($object.Ownership -eq 'AZD_OWNED_EMERGENCY_GROUP_ID') {
                    Remove-ConditionalAccessGroupReferences `
                        -GroupId $object.OwnedId `
                        -ChangedPolicyIds $changedConditionalAccessPolicies
                    Remove-TapGroupReference -GroupId $object.OwnedId
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
                            Invoke-EmergencyAccessRemediation `
                                -EmergencyAccountsGroupObjectId $object.OwnedId `
                                -CAPolicyId $policyId `
                                -SkipManagedIdentityConnection | Out-Null
                        }
                        catch {
                            $restoreErrors.Add("$policyId`: $($_.Exception.Message)")
                        }
                    }
                    if ($restoreErrors.Count -gt 0) {
                        $stateDetail = if ($groupState -eq 'unknown') {
                            " State verification also failed: $($verificationErrors -join '; ')."
                        }
                        else {
                            ''
                        }
                        throw "Emergency group cleanup failed and Conditional Access rollback was incomplete. Operation: $($deletionError.Exception.Message)$stateDetail Rollback: $($restoreErrors -join '; ')"
                    }
                    $stateDetail = if ($groupState -eq 'unknown') {
                        ' Group existence could not be confirmed after four attempts; rollback was attempted for every recorded policy change.'
                    }
                    else {
                        ' All removed Conditional Access exclusions were restored.'
                    }
                    throw "Emergency group cleanup failed.$stateDetail $($deletionError.Exception.Message)"
                }
            }
            & azd env set $object.Ownership '' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to clear $($object.Ownership)." }
            & azd env set $object.CurrentName '' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to clear $($object.CurrentName)." }
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
