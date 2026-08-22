Describe 'Optional Sentinel emergency activity alerting' {
    BeforeAll {
        $main = Get-Content "$PSScriptRoot\..\infra\main.bicep" -Raw
        $compiledMain = Get-Content "$PSScriptRoot\..\infra\main.json" -Raw | ConvertFrom-Json
        $parameters = Get-Content "$PSScriptRoot\..\infra\main.parameters.json" -Raw
        $alerting = Get-Content "$PSScriptRoot\..\infra\modules\sentinel-activity-alerting.bicep" -Raw
        $sentinelMode = Get-Content "$PSScriptRoot\..\infra\modes\sentinel-function.bicep" -Raw
        $rules = Get-Content "$PSScriptRoot\..\infra\modules\sentinel-activity-rules.bicep" -Raw
        $validate = Get-Content "$PSScriptRoot\..\scripts\Validate-Environment.ps1" -Raw
        $preProvision = Get-Content "$PSScriptRoot\..\scripts\Pre-Provision.ps1" -Raw
        $postProvision = Get-Content "$PSScriptRoot\..\scripts\Post-Provision.ps1" -Raw
        $preDown = Get-Content "$PSScriptRoot\..\scripts\Pre-Down.ps1" -Raw
        $validateWorkflow = Get-Content "$PSScriptRoot\..\.github\workflows\validate.yml" -Raw
    }

    It 'is independently opt-in and keeps the Teams webhook secret' {
        $main | Should -Match "param enableSentinelActivityAlerts string = 'false'"
        $main | Should -Match '@secure\(\)\s*param sentinelTeamsWebhookUrl string'
        $main | Should -Match "module sentinelActivityAlerting .* = if \(enableSentinelActivityAlerts == 'true'\)"
        $parameters | Should -Match 'AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS'
        $parameters | Should -Match 'AZD_SENTINEL_TEAMS_WEBHOOK_URL='
        $alerting | Should -Match "type: 'SecureString'"
        $alerting | Should -Not -Match 'outputs:.*teamsWebhookUrl'
    }

    It 'uses incident automation and a managed identity Sentinel connection' {
        $rules | Should -Match "triggersOn: 'Incidents'"
        $rules | Should -Match "triggersWhen: 'Created'"
        $rules | Should -Match "propertyName: 'IncidentRelatedAnalyticRuleIds'"
        $alerting | Should -Match "path: '/incident-creation'"
        $alerting | Should -Match "type: 'ManagedServiceIdentity'"
        $rules | Should -Match '8d289c81-5878-46d4-8554-54e1e3d8b5cb'
    }

    It 'detects sign-ins, actions by the accounts, and changes to the accounts' {
        $rules | Should -Match "SigninLogs"
        $rules | Should -Match 'UserId in~'
        $rules | Should -Match "ActorUserId = tostring\(InitiatedBy.user.id\)"
        $rules | Should -Match 'TargetUserId = tostring\(TargetResource.id\)'
        $rules | Should -Match "aggregationKind: 'AlertPerResult'"
        ($rules | Select-String -Pattern 'createIncident: true' -AllMatches).Matches.Count | Should -Be 3
    }

    It 'posts an adaptive card and optionally sends mail through an existing Outlook connection' {
        $alerting | Should -Match "Post_adaptive_card_to_Teams"
        $alerting | Should -Match 'application/vnd.microsoft.card.adaptive'
        $alerting | Should -Match "path: '/v2/Mail'"
        $validate | Should -Match 'AZD_SENTINEL_OUTLOOK_CONNECTION_RESOURCE_ID and AZD_SENTINEL_NOTIFICATION_EMAIL must be supplied together'
        $validate | Should -Match 'The Outlook API connection is not authorized'
    }

    It 'supports an authorized Teams API connection as an alternative to a webhook' {
        $main | Should -Match "param sentinelTeamsDeliveryMode string = 'admin-configured'"
        $compiledMain.parameters.sentinelTeamsDeliveryMode.defaultValue | Should -Be 'admin-configured'
        $parameters | Should -Match 'AZD_SENTINEL_TEAMS_CONNECTION_RESOURCE_ID='
        $alerting | Should -Match "teamsDeliveryMode == 'api-connection'"
        $alerting | Should -Match "Post_message_to_Teams_channel"
        $alerting | Should -Match '/beta/teams/conversation/message/poster/'
        $validate | Should -Match 'The Teams API connection is not authorized'
        $validate | Should -Match 'Teams API connection inputs must be empty when workflow-webhook delivery is selected'
    }

    It 'fails validation when the checked-in ARM template differs from compiled Bicep' {
        $validateWorkflow | Should -Match 'az bicep install --version v0.42.1'
        $validateWorkflow | Should -Match 'az bicep build --file infra/main.bicep'
        $validateWorkflow | Should -Match 'git diff --exit-code -- infra/main.json'
    }

    It 'guides an administrator through one browser authorization' {
        $main | Should -Match "'admin-configured'"
        $alerting | Should -Match "teamsDeliveryMode == 'admin-configured' \? 'Disabled' : 'Enabled'"
        $alerting | Should -Match "resource adminTeamsConnection 'Microsoft.Web/connections@2016-06-01'"
        $main | Should -Match 'AZURE_SENTINEL_TEAMS_CONNECTION_RESOURCE_ID'
        $validate | Should -Match 'right-click the target channel, select Copy link'
        $validate | Should -Match 'AZD_SENTINEL_TEAMS_CHANNEL_LINK'
        $postProvision | Should -Match 'listConsentLinks\?api-version=2016-06-01'
        $postProvision | Should -Match 'Start-Process \$Url'
        $postProvision | Should -Match 'Invoke-MgGraphRequest'
        $postProvision | Should -Match 'properties.state=Enabled'
        $postProvision | Should -Not -Match 'resource-type ms-graph'
        $postProvision | Should -Not -Match 'UseDeviceAuthentication'
    }

    It 'records and removes every cross-resource-group Sentinel object by exact ID' {
        foreach ($name in @(
            'SENTINEL_SIGNIN_RULE_ID',
            'SENTINEL_ADMIN_ACTIVITY_RULE_ID',
            'SENTINEL_ACCOUNT_CHANGE_RULE_ID',
            'SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID'
        )) {
            $preProvision | Should -Match "AZD_$name"
            $preDown | Should -Match "AZD_OWNED_$name"
        }
        $postProvision | Should -Match 'AZD_OWNED_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID'
        $preDown | Should -Match 'AZD_OWNED_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID'
        $preDown | Should -Match 'Test-OwnedSentinelResourceId'
        $preDown | Should -Match 'Test-OwnedWorkspaceRoleAssignmentId'
    }

    It 'supports a Sentinel workspace in another subscription in the same tenant' {
        $parameters | Should -Match 'AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID='
        $main | Should -Match 'param sentinelWorkspaceSubscriptionId string = subscription\(\)\.subscriptionId'
        $alerting | Should -Match 'scope: resourceGroup\(workspaceSubscriptionId, workspaceResourceGroup\)'
        $sentinelMode | Should -Match 'scope: resourceGroup\(sentinelWorkspaceSubscriptionId, sentinelWorkspaceResourceGroup\)'
        $validate | Should -Match 'Assert-SubscriptionTenant \$env:AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID'
        $preProvision | Should -Match '/subscriptions/\$env:AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID/'
        $preDown | Should -Match '-SubscriptionId \$sentinelSubscriptionId'
    }
}
