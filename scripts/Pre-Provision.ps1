[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\Validate-Environment.ps1"

function New-DeterministicGuid {
    param([Parameter(Mandatory)][string] $InputValue)
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($InputValue))
    $bytes = [byte[]]$hash[0..15]
    $bytes[7] = ($bytes[7] -band 0x0f) -bor 0x50
    $bytes[8] = ($bytes[8] -band 0x3f) -bor 0x80
    return [guid]::new($bytes)
}

function Set-OwnedSentinelResourceIds {
    param([Parameter(Mandatory)][hashtable] $Resources)

    foreach ($rule in $Resources.GetEnumerator()) {
        $ownedName = $rule.Key.Replace('AZD_', 'AZD_OWNED_')
        $ownedValue = [Environment]::GetEnvironmentVariable($ownedName)
        if ($ownedValue -and $ownedValue -ne $rule.Value) {
            throw "$ownedName already records a different exact resource. Run 'azd down' with the original Sentinel workspace settings before reprovisioning."
        }
        foreach ($name in $rule.Key, $ownedName) {
            & azd env set $name $rule.Value | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "Unable to persist deterministic Sentinel resource ID $name."
            }
            [Environment]::SetEnvironmentVariable($name, $rule.Value)
        }
    }
}

if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function' -or $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
    $workspaceId = "/subscriptions/$env:AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID/resourceGroups/$env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$env:AZD_SENTINEL_WORKSPACE_NAME"
}

if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function') {
    $rules = @{
        AZD_SENTINEL_ALERT_RULE_ID = "$workspaceId/providers/Microsoft.SecurityInsights/alertRules/$(New-DeterministicGuid "$workspaceId|$env:AZURE_ENV_NAME|emergency-access-nrt")"
        AZD_SENTINEL_AUTOMATION_RULE_ID = "$workspaceId/providers/Microsoft.SecurityInsights/automationRules/$(New-DeterministicGuid "$workspaceId|$env:AZURE_ENV_NAME|invoke-playbook")"
    }
    Set-OwnedSentinelResourceIds -Resources $rules
}

if ($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
    $activityRules = @{
        AZD_SENTINEL_SIGNIN_RULE_ID = "$workspaceId/providers/Microsoft.SecurityInsights/alertRules/$(New-DeterministicGuid "$workspaceId|$env:AZURE_ENV_NAME|activity-signin-nrt")"
        AZD_SENTINEL_ADMIN_ACTIVITY_RULE_ID = "$workspaceId/providers/Microsoft.SecurityInsights/alertRules/$(New-DeterministicGuid "$workspaceId|$env:AZURE_ENV_NAME|admin-activity-nrt")"
        AZD_SENTINEL_ACCOUNT_CHANGE_RULE_ID = "$workspaceId/providers/Microsoft.SecurityInsights/alertRules/$(New-DeterministicGuid "$workspaceId|$env:AZURE_ENV_NAME|account-change-nrt")"
        AZD_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID = "$workspaceId/providers/Microsoft.SecurityInsights/automationRules/$(New-DeterministicGuid "$workspaceId|$env:AZURE_ENV_NAME|activity-notifications")"
    }
    Set-OwnedSentinelResourceIds -Resources $activityRules
}
& "$PSScriptRoot\Bootstrap-Tenant.ps1" -Phase Identities
if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function' -and
    (-not $env:AZD_FUNCTION_AUTH_CLIENT_ID -or -not $env:AZD_FUNCTION_AUTH_AUDIENCE)) {
    throw 'Sentinel Function authentication application bootstrap did not return a client ID and audience.'
}
