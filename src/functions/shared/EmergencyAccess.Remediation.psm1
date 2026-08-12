Set-StrictMode -Version Latest

function Assert-ObjectId {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $Value
    )

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed)) {
        throw "$Name must be a valid Microsoft Entra object ID."
    }
}

function Invoke-EmergencyAccessRemediation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $EmergencyAccountsGroupObjectId,
        [string] $CAPolicyId,
        [switch] $SkipManagedIdentityConnection
    )

    Assert-ObjectId -Name 'EmergencyAccountsGroupObjectId' -Value $EmergencyAccountsGroupObjectId
    if ($CAPolicyId) {
        Assert-ObjectId -Name 'CAPolicyId' -Value $CAPolicyId
    }

    if (-not $SkipManagedIdentityConnection) {
        if ($env:MANAGED_IDENTITY_CLIENT_ID) {
            Connect-MgGraph -Identity -ClientId $env:MANAGED_IDENTITY_CLIENT_ID -NoWelcome
        }
        else {
            Connect-MgGraph -Identity -NoWelcome
        }
    }

    $policies = if ($CAPolicyId) {
        @(
            Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$CAPolicyId"
        )
    }
    else {
        $allPolicies = [System.Collections.Generic.List[object]]::new()
        $nextLink = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
        while ($nextLink) {
            $page = Invoke-MgGraphRequest -Method GET -Uri $nextLink
            foreach ($policy in @($page.value)) {
                $allPolicies.Add($policy)
            }
            $nextLink = if ($page -is [Collections.IDictionary]) {
                [string]$page['@odata.nextLink']
            }
            else {
                $nextLinkProperty = $page.PSObject.Properties['@odata.nextLink']
                if ($nextLinkProperty) { [string]$nextLinkProperty.Value } else { '' }
            }
        }
        @($allPolicies)
    }

    $updated = [System.Collections.Generic.List[string]]::new()
    $unchanged = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()

    foreach ($policy in $policies) {
        $policyId = [string]$policy.id
        $current = @(
            @($policy.conditions.users.excludeGroups) |
                Where-Object { $_ } |
                ForEach-Object { [string]$_ } |
                Select-Object -Unique
        )

        if ($EmergencyAccountsGroupObjectId -in $current) {
            $unchanged.Add($policyId)
            continue
        }

        $body = @{
            conditions = @{
                users = @{
                    excludeGroups = @($current + $EmergencyAccountsGroupObjectId | Select-Object -Unique)
                }
            }
        }

        try {
            Invoke-MgGraphRequest `
                -Method PATCH `
                -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$policyId" `
                -Body ($body | ConvertTo-Json -Depth 8 -Compress) `
                -ContentType 'application/json'
            $updated.Add($policyId)
        }
        catch {
            $failed.Add([pscustomobject]@{
                policyId = $policyId
                error = $_.Exception.Message
            })
        }
    }

    $result = [pscustomobject][ordered]@{
        mode = if ($CAPolicyId) { 'targeted' } else { 'scheduled' }
        policiesEvaluated = $policies.Count
        policiesUpdated = $updated.Count
        policiesAlreadyExcluded = $unchanged.Count
        policiesFailed = $failed.Count
        updatedPolicyIds = @($updated)
        unchangedPolicyIds = @($unchanged)
        failed = @($failed)
    }

    if ($failed.Count -gt 0) {
        $exception = [InvalidOperationException]::new(
            "Failed to remediate $($failed.Count) Conditional Access policy or policies."
        )
        $exception.Data['Result'] = $result
        throw $exception
    }

    return $result
}

Export-ModuleMember -Function Invoke-EmergencyAccessRemediation
