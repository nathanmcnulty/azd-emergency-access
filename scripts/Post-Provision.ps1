[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function') {
    foreach ($ownedOutput in @{
        AZD_OWNED_SENTINEL_ALERT_RULE_ID = $env:AZURE_SENTINEL_ALERT_RULE_ID
        AZD_OWNED_SENTINEL_AUTOMATION_RULE_ID = $env:AZURE_SENTINEL_AUTOMATION_RULE_ID
    }.GetEnumerator()) {
        if (-not $ownedOutput.Value) {
            throw "Infrastructure did not output $($ownedOutput.Key.Replace('AZD_OWNED_', 'AZURE_'))."
        }
        $existing = [Environment]::GetEnvironmentVariable($ownedOutput.Key)
        if ($existing -and $existing -ne $ownedOutput.Value) {
            throw "$($ownedOutput.Key) already records '$existing'; refusing to overwrite it with '$($ownedOutput.Value)' before exact cleanup."
        }
        & azd env set $ownedOutput.Key $ownedOutput.Value | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to persist exact Sentinel ownership record $($ownedOutput.Key)."
        }
    }
}

if ($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
    foreach ($ownedOutput in @{
        AZD_OWNED_SENTINEL_SIGNIN_RULE_ID = $env:AZURE_SENTINEL_SIGNIN_RULE_ID
        AZD_OWNED_SENTINEL_ADMIN_ACTIVITY_RULE_ID = $env:AZURE_SENTINEL_ADMIN_ACTIVITY_RULE_ID
        AZD_OWNED_SENTINEL_ACCOUNT_CHANGE_RULE_ID = $env:AZURE_SENTINEL_ACCOUNT_CHANGE_RULE_ID
        AZD_OWNED_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID = $env:AZURE_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID
        AZD_OWNED_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID = $env:AZURE_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID
    }.GetEnumerator()) {
        if (-not $ownedOutput.Value) {
            throw "Infrastructure did not output $($ownedOutput.Key.Replace('AZD_OWNED_', 'AZURE_'))."
        }
        $existing = [Environment]::GetEnvironmentVariable($ownedOutput.Key)
        if ($existing -and $existing -ne $ownedOutput.Value) {
            throw "$($ownedOutput.Key) already records '$existing'; refusing to overwrite it with '$($ownedOutput.Value)' before exact cleanup."
        }
        & azd env set $ownedOutput.Key $ownedOutput.Value | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to persist exact Sentinel ownership record $($ownedOutput.Key)."
        }
        if ($ownedOutput.Key -eq 'AZD_OWNED_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID') {
            & azd env set AZD_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID $ownedOutput.Value | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to persist the exact Sentinel Reader role-assignment record.'
            }
        }
    }
}

& "$PSScriptRoot\Bootstrap-Tenant.ps1" -Phase Workload

if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function' -or $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
    $sentinelPrincipalId = & az ad sp list `
        --display-name 'Azure Security Insights' `
        --query '[0].id' `
        --output tsv
    $playbookScope = & az group show `
        --name $env:AZURE_RESOURCE_GROUP `
        --query id `
        --output tsv

    if ($sentinelPrincipalId -and $playbookScope) {
        & az role assignment create `
            --assignee-object-id $sentinelPrincipalId `
            --assignee-principal-type ServicePrincipal `
            --role 'Microsoft Sentinel Automation Contributor' `
            --scope $playbookScope `
            --only-show-errors | Out-Null
    }

    if (-not $sentinelPrincipalId -or -not $playbookScope -or $LASTEXITCODE -ne 0) {
        Write-Warning "The Microsoft Sentinel Automation Contributor assignment could not be completed. In Microsoft Sentinel, open Settings > Playbook permissions and grant access to playbook resource group '$($env:AZURE_RESOURCE_GROUP)'."
    }

}

& azd env set AZD_PROVISIONED_MODE $env:AZD_DEPLOYMENT_MODE | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to persist the immutable provisioned deployment mode.'
}
