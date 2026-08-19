[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not $env:AZURE_RESOURCE_GROUP) {
    throw 'AZURE_RESOURCE_GROUP was not provided by the infrastructure deployment.'
}

$resources = & az resource list --resource-group $env:AZURE_RESOURCE_GROUP --query '[].{name:name,type:type}' -o json |
    ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect deployment resource group '$($env:AZURE_RESOURCE_GROUP)'."
}
if (@($resources).Count -eq 0) {
    throw "Deployment resource group '$($env:AZURE_RESOURCE_GROUP)' contains no resources."
}

Write-Host "Verified $(@($resources).Count) resource(s) for mode '$($env:AZD_DEPLOYMENT_MODE)' in '$($env:AZURE_RESOURCE_GROUP)'."

if ($env:AZD_ENABLE_SIGNIN_ALERTS -eq 'true') {
    foreach ($resourceId in $env:AZURE_SIGNIN_ALERT_RULE_ID, $env:AZURE_SIGNIN_ALERT_ACTION_GROUP_ID) {
        if (-not $resourceId) {
            throw 'Azure Monitor sign-in alerting was enabled but an expected resource output is missing.'
        }
        & az resource show --ids $resourceId --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to verify deployed Azure Monitor alert resource '$resourceId'."
        }
    }
    Write-Host 'Verified the Azure Monitor sign-in alert and action group.'
}

if ($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
    $sentinelResources = @(
        @{ Id = $env:AZURE_SENTINEL_SIGNIN_RULE_ID; ApiVersion = '2024-01-01-preview' },
        @{ Id = $env:AZURE_SENTINEL_ADMIN_ACTIVITY_RULE_ID; ApiVersion = '2024-01-01-preview' },
        @{ Id = $env:AZURE_SENTINEL_ACCOUNT_CHANGE_RULE_ID; ApiVersion = '2024-01-01-preview' },
        @{ Id = $env:AZURE_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID; ApiVersion = '2024-09-01' },
        @{ Id = $env:AZURE_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID; ApiVersion = '2022-04-01' },
        @{ Id = $env:AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID; ApiVersion = '2019-05-01' }
    )
    foreach ($resource in $sentinelResources) {
        if (-not $resource.Id) {
            throw 'Sentinel activity alerting was enabled but an expected resource output is missing.'
        }
        & az resource show --ids $resource.Id --api-version $resource.ApiVersion --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to verify deployed Sentinel activity resource '$($resource.Id)'."
        }
    }
    Write-Host 'Verified all three Sentinel activity rules, the automation rule, workspace Reader assignment, and notification playbook.'
}

