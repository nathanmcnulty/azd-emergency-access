#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Shared remediation logic for the azd-emergency-access template.

.DESCRIPTION
    Ensures a designated Microsoft Entra emergency access security group remains excluded from
    Conditional Access policies. This module is consumed identically by the Azure Automation
    runbook, the Azure Functions PowerShell app (timer and HTTP triggers), and any local/testing
    entry points so remediation behavior never drifts between deployment modes.

    Two evaluation modes are supported:
      - All policies (used by automation-scheduled, function-scheduled, logicapp-scheduled modes):
        enumerates every Conditional Access policy in the tenant.
      - Single policy (used by sentinel-function mode): remediates only the policy identified by
        CAPolicyId, as extracted from the Sentinel NRT alert.

    In both modes, existing conditions.users.excludeGroups values are preserved. The emergency
    access group is appended only when it is absent, and the PATCH body contains only the
    conditions.users.excludeGroups property so no other policy configuration is touched.
#>

Set-StrictMode -Version Latest

function Test-EmergencyAccessGroupId {
    <#
    .SYNOPSIS
        Validates that a string is a well-formed GUID suitable for use as a group object ID.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string] $GroupObjectId
    )

    if ([string]::IsNullOrWhiteSpace($GroupObjectId)) {
        return $false
    }

    $parsed = [guid]::Empty
    return [guid]::TryParse($GroupObjectId, [ref]$parsed)
}

function Get-ConditionalAccessPolicy {
    <#
    .SYNOPSIS
        Retrieves Conditional Access policies from Microsoft Graph.

    .DESCRIPTION
        Wraps Invoke-MgGraphRequest so it can be mocked in unit tests. When -PolicyId is supplied,
        only that single policy is retrieved (sentinel-function mode). Otherwise every policy in
        the tenant is retrieved (scheduled modes).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $PolicyId
    )

    if (-not [string]::IsNullOrWhiteSpace($PolicyId)) {
        $policy = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$PolicyId"
        return @($policy)
    }

    $allPolicies = [System.Collections.Generic.List[object]]::new()
    $uri = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
    do {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri
        foreach ($policy in @($response.value)) {
            $allPolicies.Add($policy)
        }

        # Under Set-StrictMode -Version Latest, accessing a property that is absent from the
        # response (the normal case on the last page) throws unless its presence is checked first.
        $nextLinkProperty = $response.PSObject.Properties['@odata.nextLink']
        $uri = if ($nextLinkProperty) { $nextLinkProperty.Value } else { $null }
    } while (-not [string]::IsNullOrWhiteSpace($uri))

    return $allPolicies.ToArray()
}

function Set-ConditionalAccessPolicyExclusion {
    <#
    .SYNOPSIS
        PATCHes a single Conditional Access policy to add the emergency access group to
        conditions.users.excludeGroups, preserving every other existing exclusion.

    .DESCRIPTION
        Wraps Invoke-MgGraphRequest so it can be mocked in unit tests. The request body contains
        only the conditions.users.excludeGroups property to avoid unintentionally overwriting any
        other policy configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PolicyId,

        [Parameter(Mandatory = $true)]
        [string[]] $ExcludeGroups
    )

    $body = @{
        conditions = @{
            users = @{
                excludeGroups = @($ExcludeGroups)
            }
        }
    }

    Invoke-MgGraphRequest -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$PolicyId" `
        -Body ($body | ConvertTo-Json -Depth 8) `
        -ContentType 'application/json'
}

function Get-PolicyExcludeGroups {
    <#
    .SYNOPSIS
        Safely reads conditions.users.excludeGroups from a Conditional Access policy object.

    .DESCRIPTION
        Uses PSObject.Properties lookups instead of direct dot-notation property access so this
        works under Set-StrictMode -Version Latest even if a nested property is entirely absent
        (rather than merely an empty array) -- which normal Microsoft Graph responses never do,
        but which test doubles or unusual API responses could.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $Policy
    )

    $conditionsProp = $Policy.PSObject.Properties['conditions']
    if (-not $conditionsProp -or -not $conditionsProp.Value) { return @() }

    $usersProp = $conditionsProp.Value.PSObject.Properties['users']
    if (-not $usersProp -or -not $usersProp.Value) { return @() }

    $excludeGroupsProp = $usersProp.Value.PSObject.Properties['excludeGroups']
    if (-not $excludeGroupsProp -or $null -eq $excludeGroupsProp.Value) { return @() }

    return @($excludeGroupsProp.Value)
}

function Invoke-EmergencyAccessRemediation {
    <#
    .SYNOPSIS
        Evaluates Conditional Access policies and ensures the emergency access group is excluded.

    .DESCRIPTION
        Core remediation entry point shared by every AZD_DEPLOYMENT_MODE. Requires an already
        authenticated Microsoft Graph context (the caller is responsible for Connect-MgGraph).

        When -CAPolicyId is supplied, only that single policy is evaluated (sentinel-function
        mode, remediating exactly the policy identified by the Sentinel NRT alert). Otherwise
        every Conditional Access policy in the tenant is enumerated (automation-scheduled,
        function-scheduled, logicapp-scheduled modes).

        Existing conditions.users.excludeGroups entries are always preserved. The emergency
        access group is appended only if it is not already present, and only a minimal PATCH body
        is sent for policies that require a change.

    .PARAMETER EmergencyAccessGroupObjectId
        Object ID (GUID) of the Microsoft Entra security group that must remain excluded from
        Conditional Access policies.

    .PARAMETER CAPolicyId
        Optional Conditional Access policy ID. When supplied, only this policy is evaluated
        (sentinel-function mode). When omitted, every policy in the tenant is evaluated.

    .OUTPUTS
        [pscustomobject] structured result with evaluated/updated/already-excluded/failed counts
        and details, safe to serialize as JSON for HTTP responses or job output.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $EmergencyAccessGroupObjectId,

        [Parameter(Mandatory = $false)]
        [string] $CAPolicyId
    )

    if (-not (Test-EmergencyAccessGroupId -GroupObjectId $EmergencyAccessGroupObjectId)) {
        throw "EmergencyAccessGroupObjectId '$EmergencyAccessGroupObjectId' is not a valid Microsoft Entra group object ID (GUID)."
    }

    if ($CAPolicyId -and -not (Test-EmergencyAccessGroupId -GroupObjectId $CAPolicyId)) {
        throw "CAPolicyId '$CAPolicyId' is not a valid Conditional Access policy ID (GUID)."
    }

    $updatedPolicyIds = [System.Collections.Generic.List[string]]::new()
    $unchangedPolicyIds = [System.Collections.Generic.List[string]]::new()
    $failedPolicies = [System.Collections.Generic.List[object]]::new()

    $policies = @(Get-ConditionalAccessPolicy -PolicyId $CAPolicyId)

    foreach ($policy in $policies) {
        if (-not $policy -or -not $policy.id) {
            continue
        }

        try {
            $currentExclusions = @(Get-PolicyExcludeGroups -Policy $policy | Where-Object { $_ })

            if ($currentExclusions -contains $EmergencyAccessGroupObjectId) {
                $unchangedPolicyIds.Add([string]$policy.id)
                continue
            }

            $mergedExclusions = @($currentExclusions + $EmergencyAccessGroupObjectId) | Select-Object -Unique

            Set-ConditionalAccessPolicyExclusion -PolicyId $policy.id -ExcludeGroups $mergedExclusions
            $updatedPolicyIds.Add([string]$policy.id)
        }
        catch {
            $failedPolicies.Add([pscustomobject]@{
                policyId = [string]$policy.id
                error    = $_.Exception.Message
            })
        }
    }

    $result = [pscustomobject][ordered]@{
        mode                    = if ($CAPolicyId) { 'single-policy' } else { 'all-policies' }
        emergencyAccessGroupId  = $EmergencyAccessGroupObjectId
        policiesEvaluated       = @($policies).Count
        policiesUpdated         = $updatedPolicyIds.Count
        policiesAlreadyExcluded = $unchangedPolicyIds.Count
        policiesFailed          = $failedPolicies.Count
        updatedPolicyIds        = @($updatedPolicyIds)
        alreadyExcludedPolicyIds = @($unchangedPolicyIds)
        failed                  = @($failedPolicies)
        succeeded               = ($failedPolicies.Count -eq 0)
        timestampUtc            = (Get-Date).ToUniversalTime().ToString('o')
    }

    return $result
}

Export-ModuleMember -Function @(
    'Test-EmergencyAccessGroupId',
    'Get-ConditionalAccessPolicy',
    'Set-ConditionalAccessPolicyExclusion',
    'Get-PolicyExcludeGroups',
    'Invoke-EmergencyAccessRemediation'
)
