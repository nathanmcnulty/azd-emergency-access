[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$allowedModes = @(
    'function-scheduled',
    'automation-scheduled',
    'logicapp-scheduled',
    'sentinel-function'
)

function Test-Interactive {
    return -not ($env:CI -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected)
}

function Set-AzdValue {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $Value
    )

    & azd env set $Name $Value | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to persist environment value for $Name."
    }
    [Environment]::SetEnvironmentVariable($Name, $Value)
}

function Set-AzdDefault {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $Value
    )

    if (-not [Environment]::GetEnvironmentVariable($Name)) {
        Set-AzdValue -Name $Name -Value $Value
    }
}

function Clear-AzdValue {
    param([Parameter(Mandatory)][string] $Name)

    & azd env set $Name '' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to clear environment value $Name."
    }
    [Environment]::SetEnvironmentVariable($Name, $null)
}

function Read-RequiredInput {
    param([Parameter(Mandatory)][string] $Prompt)

    $value = Read-Host $Prompt
    if (-not $value) {
        throw "$Prompt is required. Run 'azd up' again to continue setup."
    }
    return $value.Trim()
}

function Read-MenuSelection {
    param(
        [Parameter(Mandatory)][string] $Prompt,
        [Parameter(Mandatory)][string[]] $Options
    )

    for ($index = 0; $index -lt $Options.Count; $index++) {
        Write-Host "  $($index + 1). $($Options[$index])"
    }
    $selection = Read-Host $Prompt
    if ($selection -notmatch '^\d+$' -or
        [int]$selection -lt 1 -or [int]$selection -gt $Options.Count) {
        throw "$Prompt must be a number from 1 through $($Options.Count). Run 'azd up' again to continue setup."
    }
    return [int]$selection
}

function Read-WorkspaceConfiguration {
    param(
        [Parameter(Mandatory)][string] $Prefix,
        [Parameter(Mandatory)][string] $DisplayName
    )

    Write-Host "Configure the existing $DisplayName workspace."
    $subscriptionId = Read-Host "Subscription ID [$($env:AZURE_SUBSCRIPTION_ID)]"
    if (-not $subscriptionId) {
        $subscriptionId = $env:AZURE_SUBSCRIPTION_ID
    }
    Set-AzdValue -Name "${Prefix}_SUBSCRIPTION_ID" -Value $subscriptionId.Trim()
    Set-AzdValue -Name "${Prefix}_RESOURCE_GROUP" -Value (Read-RequiredInput "$DisplayName workspace resource group")
    Set-AzdValue -Name "${Prefix}_NAME" -Value (Read-RequiredInput "$DisplayName workspace name")
}

function Assert-GuidValue {
    param([string] $Name, [string] $Value)

    $parsed = [guid]::Empty
    if ($Value -and -not [guid]::TryParse($Value, [ref]$parsed)) {
        throw "$Name must be a GUID when supplied."
    }
}

$guidedSetup = (Test-Interactive) -and (
    -not $env:AZD_DEPLOYMENT_MODE -or $env:AZD_GUIDED_SETUP_ACTIVE -eq 'true'
)
if ($guidedSetup -and $env:AZD_GUIDED_SETUP_ACTIVE -ne 'true') {
    Set-AzdValue AZD_GUIDED_SETUP_ACTIVE 'true'
}
if (-not $env:AZD_DEPLOYMENT_MODE) {
    if (-not (Test-Interactive)) {
        throw "AZD_DEPLOYMENT_MODE is required. Allowed values: $($allowedModes -join ', ')."
    }

    Write-Host ''
    Write-Host 'Emergency access setup'
    Write-Host 'Choose how Conditional Access exclusions will be maintained:'
    $selection = Read-MenuSelection 'Deployment mode' @(
        'Scheduled Azure Function (recommended for most organizations)',
        'Azure Automation runbook',
        'Scheduled Logic App',
        'Microsoft Sentinel detection and targeted Function'
    )
    $env:AZD_DEPLOYMENT_MODE = $allowedModes[$selection - 1]
    Set-AzdValue AZD_DEPLOYMENT_MODE $env:AZD_DEPLOYMENT_MODE
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

function Assert-SubscriptionTenant {
    param([Parameter(Mandatory)][string] $SubscriptionId)

    Assert-GuidValue 'workspace subscription ID' $SubscriptionId
    if ($SubscriptionId -eq $env:AZURE_SUBSCRIPTION_ID) {
        return
    }
    $tenantId = & az account show `
        --subscription $SubscriptionId `
        --query tenantId `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $tenantId) {
        throw "Unable to access workspace subscription '$SubscriptionId' with the current Azure CLI session."
    }
    if ($tenantId -ne $env:AZURE_TENANT_ID) {
        throw "Workspace subscription '$SubscriptionId' belongs to tenant '$tenantId', not AZURE_TENANT_ID '$($env:AZURE_TENANT_ID)'."
    }
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
Set-AzdDefault AZD_MANAGE_EMERGENCY_IDENTITIES 'true'
Set-AzdDefault AZD_USE_RESTRICTED_AU 'true'
Set-AzdDefault AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT 'false'
Set-AzdDefault AZD_ENABLE_TAP_POLICY 'false'
Set-AzdDefault AZD_AUTHENTICATION_READY 'false'
Set-AzdDefault AZD_ENABLE_SIGNIN_ALERTS 'false'
Set-AzdDefault AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS 'false'
Set-AzdDefault AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY 'false'
Set-AzdDefault AZD_SENTINEL_TEAMS_DELIVERY_MODE 'admin-configured'
if (-not $env:AZD_AUTOMATION_START_TIME) {
    Set-AzdDefault AZD_AUTOMATION_START_TIME (
        [DateTimeOffset]::UtcNow.AddMinutes(15).ToString('yyyy-MM-ddTHH:mm:sszzz')
    )
}

if ($guidedSetup) {
    Write-Host ''
    Write-Host 'Choose how emergency identities will be prepared:'
    $identitySelection = Read-MenuSelection 'Identity setup' @(
        'Create and configure two new cloud-only emergency accounts (recommended)',
        'Use existing accounts and ensure group membership and Global Administrator assignments',
        'Use externally managed accounts and do not modify their identities or roles'
    )

    if ($identitySelection -eq 1) {
        Set-AzdValue AZD_MANAGE_EMERGENCY_IDENTITIES 'true'
        foreach ($name in 'AZD_EMERGENCY_USER1_ID', 'AZD_EMERGENCY_USER1_UPN', 'AZD_EMERGENCY_USER2_ID', 'AZD_EMERGENCY_USER2_UPN', 'AZD_EMERGENCY_USER3_ID', 'AZD_EMERGENCY_USER3_UPN', 'AZD_EMERGENCY_GROUP_ID') {
            Clear-AzdValue $name
        }
        $domain = Read-RequiredInput 'Verified Entra domain for the new accounts (for example, contoso.onmicrosoft.com)'
        if ($domain -match '[@\s]' -or $domain -notmatch '\.') {
            throw 'Enter a verified domain name without @, such as contoso.onmicrosoft.com.'
        }
        Set-AzdValue AZD_EMERGENCY_DOMAIN $domain
    }
    elseif ($identitySelection -eq 2) {
        Set-AzdValue AZD_MANAGE_EMERGENCY_IDENTITIES 'true'
        foreach ($number in 1, 2) {
            $reference = Read-RequiredInput "Emergency account $number UPN or object ID"
            $parsedId = [guid]::Empty
            if ([guid]::TryParse($reference, [ref]$parsedId)) {
                Clear-AzdValue "AZD_EMERGENCY_USER${number}_UPN"
                Set-AzdValue "AZD_EMERGENCY_USER${number}_ID" $reference
            }
            else {
                Clear-AzdValue "AZD_EMERGENCY_USER${number}_ID"
                Set-AzdValue "AZD_EMERGENCY_USER${number}_UPN" $reference
            }
        }
        $existingGroupId = Read-Host 'Existing emergency group object ID (leave blank to create one)'
        if ($existingGroupId) {
            Set-AzdValue AZD_EMERGENCY_GROUP_ID $existingGroupId.Trim()
        }
        else {
            Clear-AzdValue AZD_EMERGENCY_GROUP_ID
        }
    }
    else {
        Set-AzdValue AZD_MANAGE_EMERGENCY_IDENTITIES 'false'
        Clear-AzdValue AZD_EMERGENCY_USER1_UPN
        Clear-AzdValue AZD_EMERGENCY_USER2_UPN
        Set-AzdValue AZD_EMERGENCY_GROUP_ID (Read-RequiredInput 'Externally managed emergency group object ID')
        Set-AzdValue AZD_EMERGENCY_USER1_ID (Read-RequiredInput 'Emergency account 1 object ID')
        Set-AzdValue AZD_EMERGENCY_USER2_ID (Read-RequiredInput 'Emergency account 2 object ID')
        Set-AzdValue AZD_ENABLE_TAP_POLICY 'false'
    }

    if ($identitySelection -ne 3) {
        Write-Host ''
        $limitedSelection = Read-MenuSelection 'Limited recovery account' @(
            'Do not add a third account (recommended for the standard Microsoft design)',
            'Add a third account for Conditional Access and authentication-policy recovery'
        )
        Set-AzdValue AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT $(if ($limitedSelection -eq 2) { 'true' } else { 'false' })
        if ($limitedSelection -eq 2 -and $identitySelection -eq 2) {
            $reference = Read-RequiredInput 'Limited emergency account UPN or object ID'
            $parsedId = [guid]::Empty
            if ([guid]::TryParse($reference, [ref]$parsedId)) {
                Clear-AzdValue AZD_EMERGENCY_USER3_UPN
                Set-AzdValue AZD_EMERGENCY_USER3_ID $reference
            }
            else {
                Clear-AzdValue AZD_EMERGENCY_USER3_ID
                Set-AzdValue AZD_EMERGENCY_USER3_UPN $reference
            }
        }
        elseif ($limitedSelection -eq 1) {
            Clear-AzdValue AZD_EMERGENCY_USER3_ID
            Clear-AzdValue AZD_EMERGENCY_USER3_UPN
        }

        Write-Host ''
        Write-Host 'Temporary Access Pass (TAP) provides the one-time credential needed to register passkeys.'
        $tapSelection = Read-MenuSelection 'TAP onboarding' @(
            'Enable TAP onboarding and show each pass once (recommended)',
            'Skip TAP changes and configure authentication methods separately'
        )
        Set-AzdValue AZD_ENABLE_TAP_POLICY $(if ($tapSelection -eq 1) { 'true' } else { 'false' })
    }
    else {
        Set-AzdValue AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT 'false'
    }

    Write-Host ''
    Write-Host 'Choose emergency-account use notifications. Existing Entra log ingestion is required.'
    $alertSelection = Read-MenuSelection 'Alerting' @(
        'Azure Monitor email from SigninLogs',
        'Microsoft Sentinel incidents and a Teams channel message',
        'Both Azure Monitor email and Sentinel/Teams',
        'Configure alerting later'
    )
    $enableSignIn = $alertSelection -in 1, 3
    $enableSentinelActivity = $alertSelection -in 2, 3
    Set-AzdValue AZD_ENABLE_SIGNIN_ALERTS $(if ($enableSignIn) { 'true' } else { 'false' })
    Set-AzdValue AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS $(if ($enableSentinelActivity) { 'true' } else { 'false' })
    if ($alertSelection -eq 4) {
        Write-Warning 'Emergency-account use will not be monitored by this deployment until alerting is configured.'
    }

    if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function' -or $enableSentinelActivity) {
        Read-WorkspaceConfiguration -Prefix 'AZD_SENTINEL_WORKSPACE' -DisplayName 'Sentinel'
    }
    if ($enableSignIn) {
        if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function' -or $enableSentinelActivity) {
            Write-Host 'The configured Sentinel workspace will also be used for SigninLogs.'
        }
        else {
            Read-WorkspaceConfiguration -Prefix 'AZD_SIGNIN_LOG_WORKSPACE' -DisplayName 'SigninLogs'
        }
        Set-AzdValue AZD_SIGNIN_ALERT_EMAIL (Read-RequiredInput 'Email address for critical sign-in alerts')
    }

    Write-Host ''
    Write-Host 'Setup choices are saved in the current azd environment.'
    Write-Host "  Remediation: $($env:AZD_DEPLOYMENT_MODE)"
    Write-Host "  Identity management: $($env:AZD_MANAGE_EMERGENCY_IDENTITIES)"
    Write-Host "  Limited recovery account: $($env:AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT)"
    Write-Host "  TAP onboarding: $($env:AZD_ENABLE_TAP_POLICY)"
    Write-Host "  Azure Monitor email: $($env:AZD_ENABLE_SIGNIN_ALERTS)"
    Write-Host "  Sentinel and Teams: $($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS)"
    Set-AzdValue AZD_GUIDED_SETUP_ACTIVE 'false'
    Write-Host 'Continuing with tenant validation and deployment.'
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

foreach ($booleanName in 'AZD_MANAGE_EMERGENCY_IDENTITIES', 'AZD_USE_RESTRICTED_AU', 'AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT', 'AZD_ENABLE_TAP_POLICY', 'AZD_AUTHENTICATION_READY', 'AZD_ENABLE_SIGNIN_ALERTS', 'AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS', 'AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY') {
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
    if ($env:AZD_SIGNIN_LOG_WORKSPACE_SUBSCRIPTION_ID) {
        Set-AzdDefault AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID $env:AZD_SIGNIN_LOG_WORKSPACE_SUBSCRIPTION_ID
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
            if (-not $env:AZD_SENTINEL_TEAMS_CHANNEL_LINK -and (Test-Interactive)) {
                Write-Host 'In Microsoft Teams, right-click the target channel, select Copy link, then paste it here.'
                $channelLink = Read-Host 'Teams channel link'
                if ($channelLink) {
                    & azd env set AZD_SENTINEL_TEAMS_CHANNEL_LINK $channelLink | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        throw 'Unable to persist AZD_SENTINEL_TEAMS_CHANNEL_LINK.'
                    }
                    $env:AZD_SENTINEL_TEAMS_CHANNEL_LINK = $channelLink
                }
            }
            if (-not $env:AZD_SENTINEL_TEAMS_CHANNEL_LINK) {
                throw 'Admin-configured delivery requires a copied Teams channel link or explicit team and channel IDs.'
            }

            try {
                $channelUri = [uri]$env:AZD_SENTINEL_TEAMS_CHANNEL_LINK
                $segments = $channelUri.AbsolutePath.Trim('/').Split('/') |
                    ForEach-Object { [uri]::UnescapeDataString($_) }
                if ($segments.Length -lt 4 -or $segments[0] -ne 'l' -or $segments[1] -ne 'channel') {
                    throw 'unsupported path'
                }
                $query = [System.Web.HttpUtility]::ParseQueryString($channelUri.Query)
                $channelId = $segments[2]
                $teamId = $query['groupId']
                $channelTenantId = $query['tenantId']
            }
            catch {
                throw 'AZD_SENTINEL_TEAMS_CHANNEL_LINK must be a channel link copied from Microsoft Teams.'
            }
            if (-not $teamId -or -not $channelId -or -not $channelTenantId) {
                throw 'Unable to resolve the team, channel, and tenant IDs from AZD_SENTINEL_TEAMS_CHANNEL_LINK.'
            }
            if ($channelTenantId -ne $env:AZURE_TENANT_ID) {
                throw "The Teams channel tenant '$channelTenantId' does not match AZURE_TENANT_ID '$($env:AZURE_TENANT_ID)'."
            }
            Set-AzdDefault AZD_SENTINEL_TEAMS_TEAM_ID $teamId
            Set-AzdDefault AZD_SENTINEL_TEAMS_CHANNEL_ID $channelId
        }
        if (-not $env:AZD_SENTINEL_TEAMS_TEAM_ID -or -not $env:AZD_SENTINEL_TEAMS_CHANNEL_ID) {
            throw 'Admin-configured delivery could not resolve the team ID and channel ID.'
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
        if ($env:AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID) {
            Set-AzdDefault AZD_SIGNIN_LOG_WORKSPACE_SUBSCRIPTION_ID $env:AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID
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

    Set-AzdDefault AZD_SIGNIN_LOG_WORKSPACE_SUBSCRIPTION_ID $env:AZURE_SUBSCRIPTION_ID
    Assert-SubscriptionTenant $env:AZD_SIGNIN_LOG_WORKSPACE_SUBSCRIPTION_ID
    $signInWorkspaceId = "/subscriptions/$env:AZD_SIGNIN_LOG_WORKSPACE_SUBSCRIPTION_ID/resourceGroups/$env:AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$env:AZD_SIGNIN_LOG_WORKSPACE_NAME"
    & az resource show --ids $signInWorkspaceId --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Sign-in log workspace '$($env:AZD_SIGNIN_LOG_WORKSPACE_NAME)' was not found in resource group '$($env:AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP)'."
    }
}

foreach ($guidName in @(
    'AZD_EMERGENCY_USER1_ID',
    'AZD_EMERGENCY_USER2_ID',
    'AZD_EMERGENCY_USER3_ID',
    'AZD_EMERGENCY_GROUP_ID',
    'AZD_ADMINISTRATIVE_UNIT_ID'
)) {
    Assert-GuidValue $guidName ([Environment]::GetEnvironmentVariable($guidName))
}

if ($env:AZD_MANAGE_EMERGENCY_IDENTITIES -eq 'false') {
    if (-not $env:AZD_EMERGENCY_GROUP_ID) {
        throw 'AZD_MANAGE_EMERGENCY_IDENTITIES=false requires AZD_EMERGENCY_GROUP_ID.'
    }
    if (($env:AZD_ENABLE_SIGNIN_ALERTS -eq 'true' -or
        $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') -and
        (-not $env:AZD_EMERGENCY_USER1_ID -or -not $env:AZD_EMERGENCY_USER2_ID)) {
        throw 'Alerting with externally managed emergency identities requires AZD_EMERGENCY_USER1_ID and AZD_EMERGENCY_USER2_ID.'
    }
    if ($env:AZD_ENABLE_TAP_POLICY -eq 'true') {
        throw 'AZD_ENABLE_TAP_POLICY cannot be true when AZD_MANAGE_EMERGENCY_IDENTITIES=false.'
    }
    if ($env:AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT -eq 'true') {
        throw 'The optional limited emergency account is only supported when AZD_MANAGE_EMERGENCY_IDENTITIES=true.'
    }
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
    Set-AzdDefault AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID $env:AZURE_SUBSCRIPTION_ID
    Assert-SubscriptionTenant $env:AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID
    $workspaceId = "/subscriptions/$env:AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID/resourceGroups/$env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$env:AZD_SENTINEL_WORKSPACE_NAME"
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
$user3Missing = -not $env:AZD_EMERGENCY_USER3_ID -and -not $env:AZD_EMERGENCY_USER3_UPN
if ($env:AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT -eq 'true' -and $user3Missing -and -not $env:AZD_EMERGENCY_DOMAIN) {
    throw 'The limited emergency account requires AZD_EMERGENCY_USER3_ID, AZD_EMERGENCY_USER3_UPN, or AZD_EMERGENCY_DOMAIN.'
}
if ($env:AZD_MANAGE_EMERGENCY_IDENTITIES -eq 'true' -and ($user1Missing -or $user2Missing) -and $env:AZD_ENABLE_TAP_POLICY -ne 'true') {
    throw 'Creating emergency accounts requires AZD_ENABLE_TAP_POLICY=true so usable phishing-resistant authentication is registered before roles are assigned.'
}
if ($env:AZD_MANAGE_EMERGENCY_IDENTITIES -eq 'true' -and
    ($user1Missing -or $user2Missing) -and -not $env:AZD_EMERGENCY_DOMAIN) {
    throw 'Set AZD_EMERGENCY_DOMAIN when either emergency user needs to be created.'
}

Write-Host "Environment contract validated for '$($env:AZD_DEPLOYMENT_MODE)'."
