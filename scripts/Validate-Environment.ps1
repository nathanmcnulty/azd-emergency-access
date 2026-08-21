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
if (-not $env:AZURE_SUBSCRIPTION_ID) {
    throw 'AZURE_SUBSCRIPTION_ID is required.'
}
if (-not $env:AZURE_TENANT_ID) {
    $subscriptionTenantId = & az account show `
        --subscription $env:AZURE_SUBSCRIPTION_ID `
        --query tenantId `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $subscriptionTenantId) {
        throw 'Unable to resolve AZURE_TENANT_ID from AZURE_SUBSCRIPTION_ID.'
    }
    Set-AzdDefault AZURE_TENANT_ID $subscriptionTenantId
}
Set-AzdDefault AZD_SCHEDULE_CRON '0 0 */6 * * *'
Set-AzdDefault AZD_SCHEDULE_INTERVAL '6'
Set-AzdDefault AZD_SCHEDULE_FREQUENCY 'Hour'
Set-AzdDefault AZD_AUTOMATION_TIME_ZONE 'Etc/UTC'
Set-AzdDefault AZD_USE_RESTRICTED_AU 'true'
Set-AzdDefault AZD_ENABLE_TAP_POLICY 'false'
Set-AzdDefault AZD_ENABLE_SIGNIN_ALERTS 'false'
Set-AzdDefault AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS 'false'
Set-AzdDefault AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY 'false'
Set-AzdDefault AZD_SENTINEL_TEAMS_DELIVERY_MODE 'workflow-webhook'
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
    $resourceGroupExists = & az group exists `
        --subscription $env:AZURE_SUBSCRIPTION_ID `
        --name $resourceGroupName `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to check whether resource group '$resourceGroupName' exists."
    }
    $scheduleExists = $false
    if ($resourceGroupExists -eq 'true') {
        & az automation schedule show `
            --subscription $env:AZURE_SUBSCRIPTION_ID `
            --resource-group $resourceGroupName `
            --automation-account-name "$($env:AZURE_ENV_NAME)-aa" `
            --name emergency-access `
            --only-show-errors 2>$null | Out-Null
        $scheduleExists = $LASTEXITCODE -eq 0
    }

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

foreach ($booleanName in 'AZD_USE_RESTRICTED_AU', 'AZD_ENABLE_TAP_POLICY', 'AZD_ENABLE_SIGNIN_ALERTS', 'AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS', 'AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY') {
    $value = [Environment]::GetEnvironmentVariable($booleanName)
    if ($value -notin 'true', 'false') {
        throw "$booleanName must be 'true' or 'false'."
    }
}

if ($env:AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY -eq 'true' -and
    $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -ne 'true') {
    throw 'AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY requires AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS=true.'
}
if ($env:AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY -eq 'true' -and
    $env:AZD_SENTINEL_TEAMS_DELIVERY_MODE -eq 'admin-configured') {
    throw 'Notification delivery cannot be tested while the admin-configured playbook is intentionally disabled.'
}

if ($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
    if ($env:AZD_SIGNIN_LOG_WORKSPACE_NAME) {
        Set-AzdDefault AZD_SENTINEL_WORKSPACE_NAME $env:AZD_SIGNIN_LOG_WORKSPACE_NAME
    }
    if ($env:AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP) {
        Set-AzdDefault AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP $env:AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP
    }
    if ($env:AZD_SENTINEL_TEAMS_DELIVERY_MODE -notin 'workflow-webhook', 'api-connection', 'admin-configured') {
        throw 'AZD_SENTINEL_TEAMS_DELIVERY_MODE must be workflow-webhook, api-connection, or admin-configured.'
    }
    if ($env:AZD_SENTINEL_TEAMS_DELIVERY_MODE -eq 'workflow-webhook') {
        if (-not $env:AZD_SENTINEL_TEAMS_WEBHOOK_URL) {
            throw 'Workflow-webhook delivery requires AZD_SENTINEL_TEAMS_WEBHOOK_URL.'
        }
        if ($env:AZD_SENTINEL_TEAMS_CONNECTION_RESOURCE_ID -or
            $env:AZD_SENTINEL_TEAMS_TEAM_ID -or $env:AZD_SENTINEL_TEAMS_CHANNEL_ID) {
            throw 'Teams API connection inputs must be empty when workflow-webhook delivery is selected.'
        }
        $teamsWebhook = $null
        if (-not [uri]::TryCreate($env:AZD_SENTINEL_TEAMS_WEBHOOK_URL, [UriKind]::Absolute, [ref]$teamsWebhook) -or
            $teamsWebhook.Scheme -ne 'https' -or $teamsWebhook.UserInfo) {
            throw 'AZD_SENTINEL_TEAMS_WEBHOOK_URL must be an absolute HTTPS URL without embedded credentials.'
        }
    }
    elseif ($env:AZD_SENTINEL_TEAMS_DELIVERY_MODE -eq 'api-connection') {
        if ($env:AZD_SENTINEL_TEAMS_WEBHOOK_URL) {
            throw 'AZD_SENTINEL_TEAMS_WEBHOOK_URL must be empty when api-connection delivery is selected.'
        }
        if (-not $env:AZD_SENTINEL_TEAMS_CONNECTION_RESOURCE_ID -or
            -not $env:AZD_SENTINEL_TEAMS_TEAM_ID -or -not $env:AZD_SENTINEL_TEAMS_CHANNEL_ID) {
            throw 'API-connection delivery requires the Teams connection resource ID, team ID, and channel ID.'
        }
        $teamsConnectionId = $env:AZD_SENTINEL_TEAMS_CONNECTION_RESOURCE_ID
        if ($teamsConnectionId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Web/connections/[^/]+$' -or
            -not $teamsConnectionId.StartsWith("/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'AZD_SENTINEL_TEAMS_CONNECTION_RESOURCE_ID must be a Microsoft.Web/connections resource in AZURE_SUBSCRIPTION_ID.'
        }
        $teamsConnection = & az resource show --ids $teamsConnectionId --api-version 2016-06-01 --output json --only-show-errors |
            ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $teamsConnection) {
            throw "Teams API connection '$teamsConnectionId' was not found."
        }
        if ($teamsConnection.location -ne $env:AZURE_LOCATION -or $teamsConnection.properties.api.name -ne 'teams') {
            throw "The Teams API connection must use the Teams managed API in AZURE_LOCATION '$($env:AZURE_LOCATION)'."
        }
        $teamsConnectionStatus = @($teamsConnection.properties.statuses)[0].status
        if ($teamsConnectionStatus -notin 'Authenticated', 'Connected', 'Ready') {
            throw "The Teams API connection is not authorized; its status is '$teamsConnectionStatus'."
        }
    }
    else {
        if ($env:AZD_SENTINEL_TEAMS_WEBHOOK_URL -or $env:AZD_SENTINEL_TEAMS_CONNECTION_RESOURCE_ID) {
            throw 'Teams webhook and connection resource ID must be empty when admin-configured delivery is selected.'
        }
        if (-not $env:AZD_SENTINEL_TEAMS_TEAM_ID -or -not $env:AZD_SENTINEL_TEAMS_CHANNEL_ID) {
            throw 'Admin-configured delivery requires the team ID and channel ID.'
        }
    }

    $outlookConnectionId = $env:AZD_SENTINEL_OUTLOOK_CONNECTION_RESOURCE_ID
    $sentinelNotificationEmail = $env:AZD_SENTINEL_NOTIFICATION_EMAIL
    if ([bool]$outlookConnectionId -xor [bool]$sentinelNotificationEmail) {
        throw 'AZD_SENTINEL_OUTLOOK_CONNECTION_RESOURCE_ID and AZD_SENTINEL_NOTIFICATION_EMAIL must be supplied together.'
    }
    if ($sentinelNotificationEmail) {
        try {
            $mailAddress = [System.Net.Mail.MailAddress]::new($sentinelNotificationEmail)
        }
        catch {
            throw 'AZD_SENTINEL_NOTIFICATION_EMAIL must be a valid email address.'
        }
        if ($mailAddress.Address -ne $sentinelNotificationEmail) {
            throw 'AZD_SENTINEL_NOTIFICATION_EMAIL must contain one plain email address without a display name.'
        }
        if ($outlookConnectionId -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Web/connections/[^/]+$') {
            throw 'AZD_SENTINEL_OUTLOOK_CONNECTION_RESOURCE_ID must be a Microsoft.Web/connections resource ID.'
        }
        if (-not $outlookConnectionId.StartsWith("/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'AZD_SENTINEL_OUTLOOK_CONNECTION_RESOURCE_ID must be in AZURE_SUBSCRIPTION_ID.'
        }
        $outlookConnection = & az resource show --ids $outlookConnectionId --api-version 2016-06-01 --output json --only-show-errors |
            ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or -not $outlookConnection) {
            throw "Outlook API connection '$outlookConnectionId' was not found."
        }
        if ($outlookConnection.location -ne $env:AZURE_LOCATION) {
            throw "The Outlook API connection must be in AZURE_LOCATION '$($env:AZURE_LOCATION)'."
        }
        $connectionStatus = @($outlookConnection.properties.statuses)[0].status
        if ($connectionStatus -notin 'Authenticated', 'Connected', 'Ready') {
            throw "The Outlook API connection is not authorized; its status is '$connectionStatus'."
        }
    }
}

if ($env:AZD_ENABLE_SIGNIN_ALERTS -eq 'true') {
    if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function' -or $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
        if ($env:AZD_SENTINEL_WORKSPACE_NAME) {
            Set-AzdDefault AZD_SIGNIN_LOG_WORKSPACE_NAME $env:AZD_SENTINEL_WORKSPACE_NAME
        }
        if ($env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP) {
            Set-AzdDefault AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP $env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP
        }
    }
    if (-not $env:AZD_SIGNIN_LOG_WORKSPACE_NAME -or -not $env:AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP) {
        throw 'Sign-in alerting requires AZD_SIGNIN_LOG_WORKSPACE_NAME and AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP.'
    }
    if (-not $env:AZD_SIGNIN_ALERT_EMAIL) {
        throw 'Sign-in alerting requires AZD_SIGNIN_ALERT_EMAIL.'
    }
    try {
        $alertEmail = [System.Net.Mail.MailAddress]::new($env:AZD_SIGNIN_ALERT_EMAIL)
    }
    catch {
        throw 'AZD_SIGNIN_ALERT_EMAIL must be a valid email address.'
    }
    if ($alertEmail.Address -ne $env:AZD_SIGNIN_ALERT_EMAIL) {
        throw 'AZD_SIGNIN_ALERT_EMAIL must contain one plain email address without a display name.'
    }

    $signInWorkspaceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$env:AZD_SIGNIN_LOG_WORKSPACE_NAME"
    & az resource show --ids $signInWorkspaceId --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Sign-in log workspace '$($env:AZD_SIGNIN_LOG_WORKSPACE_NAME)' was not found in resource group '$($env:AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP)'."
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

if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function' -or $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
    if (-not $env:AZD_SENTINEL_WORKSPACE_NAME -or -not $env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP) {
        throw 'Sentinel mode requires AZD_SENTINEL_WORKSPACE_NAME and AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP.'
    }
    $workspaceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$env:AZD_SENTINEL_WORKSPACE_NAME"
    $expectedAlertRuleId = "$workspaceId/providers/Microsoft.SecurityInsights/alertRules/"
    $expectedAutomationRuleId = "$workspaceId/providers/Microsoft.SecurityInsights/automationRules/"
    foreach ($ownership in @(
        @{ Name = 'AZD_OWNED_SENTINEL_ALERT_RULE_ID'; ExpectedPrefix = $expectedAlertRuleId },
        @{ Name = 'AZD_OWNED_SENTINEL_AUTOMATION_RULE_ID'; ExpectedPrefix = $expectedAutomationRuleId },
        @{ Name = 'AZD_OWNED_SENTINEL_SIGNIN_RULE_ID'; ExpectedPrefix = $expectedAlertRuleId },
        @{ Name = 'AZD_OWNED_SENTINEL_ADMIN_ACTIVITY_RULE_ID'; ExpectedPrefix = $expectedAlertRuleId },
        @{ Name = 'AZD_OWNED_SENTINEL_ACCOUNT_CHANGE_RULE_ID'; ExpectedPrefix = $expectedAlertRuleId },
        @{ Name = 'AZD_OWNED_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID'; ExpectedPrefix = $expectedAutomationRuleId },
        @{
            Name = 'AZD_OWNED_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID'
            ExpectedPrefix = "$workspaceId/providers/Microsoft.Authorization/roleAssignments/"
        }
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
