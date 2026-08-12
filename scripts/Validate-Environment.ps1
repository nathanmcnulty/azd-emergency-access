[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$allowedModes = @(
    'automation-scheduled',
    'function-scheduled',
    'logicapp-scheduled',
    'sentinel-function'
)

function Test-Interactive {
    return -not ($env:CI -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected)
}

function Set-AzdDefault {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $Value
    )

    if (-not [Environment]::GetEnvironmentVariable($Name)) {
        & azd env set $Name $Value | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to persist default value for $Name."
        }
        [Environment]::SetEnvironmentVariable($Name, $Value)
    }
}

function Assert-GuidValue {
    param([string] $Name, [string] $Value)

    $parsed = [guid]::Empty
    if ($Value -and -not [guid]::TryParse($Value, [ref]$parsed)) {
        throw "$Name must be a GUID when supplied."
    }
}

if (-not $env:AZD_DEPLOYMENT_MODE) {
    if (-not (Test-Interactive)) {
        throw "AZD_DEPLOYMENT_MODE is required. Allowed values: $($allowedModes -join ', ')."
    }

    Write-Host 'Choose one deployment mode:'
    for ($index = 0; $index -lt $allowedModes.Count; $index++) {
        Write-Host "  $($index + 1). $($allowedModes[$index])"
    }
    $selection = Read-Host 'Selection'
    if ($selection -notmatch '^[1-4]$') {
        throw 'Deployment mode selection must be a number from 1 through 4.'
    }
    $env:AZD_DEPLOYMENT_MODE = $allowedModes[[int]$selection - 1]
    & azd env set AZD_DEPLOYMENT_MODE $env:AZD_DEPLOYMENT_MODE | Out-Null
}

if ($env:AZD_DEPLOYMENT_MODE -notin $allowedModes) {
    throw "Unsupported AZD_DEPLOYMENT_MODE '$($env:AZD_DEPLOYMENT_MODE)'. Allowed values: $($allowedModes -join ', ')."
}
if ($env:AZD_PROVISIONED_MODE -and $env:AZD_PROVISIONED_MODE -ne $env:AZD_DEPLOYMENT_MODE) {
    throw "This azd environment is locked to provisioned mode '$($env:AZD_PROVISIONED_MODE)'. Run 'azd down' before changing AZD_DEPLOYMENT_MODE, or use a new azd environment."
}

Set-AzdDefault AZURE_LOCATION 'westus2'
Set-AzdDefault AZD_SCHEDULE_CRON '0 0 */6 * * *'
Set-AzdDefault AZD_SCHEDULE_INTERVAL '6'
Set-AzdDefault AZD_SCHEDULE_FREQUENCY 'Hour'
Set-AzdDefault AZD_AUTOMATION_TIME_ZONE 'Etc/UTC'
Set-AzdDefault AZD_USE_RESTRICTED_AU 'true'
Set-AzdDefault AZD_ENABLE_TAP_POLICY 'false'
if (-not $env:AZD_AUTOMATION_START_TIME) {
    Set-AzdDefault AZD_AUTOMATION_START_TIME (
        [DateTimeOffset]::UtcNow.AddMinutes(15).ToString('yyyy-MM-ddTHH:mm:sszzz')
    )
}
if ($env:AZD_DEPLOYMENT_MODE -eq 'automation-scheduled') {
    $resourceGroupName = if ($env:AZURE_RESOURCE_GROUP) {
        $env:AZURE_RESOURCE_GROUP
    }
    else {
        "rg-$($env:AZURE_ENV_NAME)"
    }
    & az automation schedule show `
        --resource-group $resourceGroupName `
        --automation-account-name "$($env:AZURE_ENV_NAME)-aa" `
        --name emergency-access `
        --only-show-errors | Out-Null
    $scheduleExists = $LASTEXITCODE -eq 0

    $parsedStart = [DateTimeOffset]::MinValue
    $validStart = [DateTimeOffset]::TryParse($env:AZD_AUTOMATION_START_TIME, [ref]$parsedStart)
    if (-not $scheduleExists -and
        (-not $validStart -or $parsedStart -lt [DateTimeOffset]::UtcNow.AddMinutes(10))) {
        $newStart = [DateTimeOffset]::UtcNow.AddMinutes(15).ToString('yyyy-MM-ddTHH:mm:sszzz')
        & azd env set AZD_AUTOMATION_START_TIME $newStart | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to persist a safe Automation schedule start time.'
        }
        $env:AZD_AUTOMATION_START_TIME = $newStart
    }
}

foreach ($booleanName in 'AZD_USE_RESTRICTED_AU', 'AZD_ENABLE_TAP_POLICY') {
    $value = [Environment]::GetEnvironmentVariable($booleanName)
    if ($value -notin 'true', 'false') {
        throw "$booleanName must be 'true' or 'false'."
    }
}

foreach ($guidName in @(
    'AZD_EMERGENCY_USER1_ID',
    'AZD_EMERGENCY_USER2_ID',
    'AZD_EMERGENCY_GROUP_ID',
    'AZD_ADMINISTRATIVE_UNIT_ID'
)) {
    Assert-GuidValue $guidName ([Environment]::GetEnvironmentVariable($guidName))
}

if ($env:AZD_SCHEDULE_CRON -notmatch '^\S+(\s+\S+){5}$') {
    throw 'AZD_SCHEDULE_CRON must be a six-field NCRONTAB expression.'
}
if ($env:AZD_SCHEDULE_INTERVAL -notmatch '^[1-9][0-9]*$') {
    throw 'AZD_SCHEDULE_INTERVAL must be a positive integer.'
}
if ($env:AZD_SCHEDULE_FREQUENCY -notin 'Minute', 'Hour', 'Day', 'Week', 'Month') {
    throw 'AZD_SCHEDULE_FREQUENCY must be Minute, Hour, Day, Week, or Month.'
}

if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function') {
    if (-not $env:AZD_SENTINEL_WORKSPACE_NAME -or -not $env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP) {
        throw 'Sentinel mode requires AZD_SENTINEL_WORKSPACE_NAME and AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP.'
    }
    $workspaceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$env:AZD_SENTINEL_WORKSPACE_NAME"
    $expectedAlertRuleId = "$workspaceId/providers/Microsoft.SecurityInsights/alertRules/"
    $expectedAutomationRuleId = "$workspaceId/providers/Microsoft.SecurityInsights/automationRules/"
    foreach ($ownership in @(
        @{ Name = 'AZD_OWNED_SENTINEL_ALERT_RULE_ID'; ExpectedPrefix = $expectedAlertRuleId },
        @{ Name = 'AZD_OWNED_SENTINEL_AUTOMATION_RULE_ID'; ExpectedPrefix = $expectedAutomationRuleId }
    )) {
        $current = [Environment]::GetEnvironmentVariable($ownership.Name)
        if ($current -and -not $current.StartsWith($ownership.ExpectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$($ownership.Name) records a different Sentinel workspace. Run 'azd down' with the original workspace settings before changing workspaces."
        }
    }
    & az resource show --ids $workspaceId --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Sentinel workspace '$($env:AZD_SENTINEL_WORKSPACE_NAME)' was not found in resource group '$($env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP)'."
    }
    $onboardingId = "$workspaceId/providers/Microsoft.SecurityInsights/onboardingStates/default"
    & az resource show --ids $onboardingId --api-version 2024-09-01 --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Workspace '$($env:AZD_SENTINEL_WORKSPACE_NAME)' is not confirmed as Microsoft Sentinel-enabled."
    }
}

$user1Missing = -not $env:AZD_EMERGENCY_USER1_ID -and -not $env:AZD_EMERGENCY_USER1_UPN
$user2Missing = -not $env:AZD_EMERGENCY_USER2_ID -and -not $env:AZD_EMERGENCY_USER2_UPN
if (($user1Missing -or $user2Missing) -and -not $env:AZD_EMERGENCY_DOMAIN) {
    throw 'Set AZD_EMERGENCY_DOMAIN when either emergency user needs to be created.'
}

Write-Host "Environment contract validated for '$($env:AZD_DEPLOYMENT_MODE)'."
