targetScope = 'resourceGroup'

@allowed([
  'automation-scheduled'
  'function-scheduled'
  'logicapp-scheduled'
  'sentinel-function'
])
param deploymentMode string
param location string = resourceGroup().location
param namePrefix string
param tags object = {}
param emergencyAccessGroupObjectId string = ''
param scheduleCron string = '0 0 2 * * *'
@allowed([
  'Minute'
  'Hour'
  'Day'
  'Week'
  'Month'
])
param scheduleFrequency string = 'Day'
param scheduleInterval string = '1'
param scheduleTimeZone string = 'UTC'
param scheduleStartTime string = ''
param generatedScheduleStartTime string = dateTimeAdd(utcNow('u'), 'PT15M')
param sentinelWorkspaceName string = ''
param sentinelWorkspaceSubscriptionId string = subscription().subscriptionId
param sentinelWorkspaceResourceGroup string = ''
param sentinelKql string = ''
param functionAuthClientId string = ''
param functionAuthAudience string = ''
param sentinelServicePrincipalId string = ''
param sentinelAlertRuleId string = ''
param sentinelAutomationRuleId string = ''
@allowed([
  'true'
  'false'
])
param enableSignInAlerts string = 'false'
param signInLogWorkspaceName string = ''
param signInLogWorkspaceSubscriptionId string = subscription().subscriptionId
param signInLogWorkspaceResourceGroup string = ''
param signInAlertEmail string = ''
@allowed([
  'true'
  'false'
])
param enableSentinelActivityAlerts string = 'false'
@secure()
param sentinelTeamsWebhookUrl string = ''
@allowed([
  'workflow-webhook'
  'api-connection'
  'admin-configured'
])
param sentinelTeamsDeliveryMode string = 'admin-configured'
param sentinelTeamsConnectionResourceId string = ''
param sentinelTeamsTeamId string = ''
param sentinelTeamsChannelId string = ''
param sentinelOutlookConnectionResourceId string = ''
param sentinelNotificationEmail string = ''
param sentinelSignInRuleId string = ''
param sentinelAdminActivityRuleId string = ''
param sentinelAccountChangeRuleId string = ''
param sentinelNotificationAutomationRuleId string = ''
param emergencyUser1ObjectId string = ''
param emergencyUser2ObjectId string = ''
var effectiveScheduleStartTime = empty(scheduleStartTime)
  ? generatedScheduleStartTime
  : scheduleStartTime

resource signInLogWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = if (enableSignInAlerts == 'true') {
  name: signInLogWorkspaceName
  scope: resourceGroup(signInLogWorkspaceSubscriptionId, signInLogWorkspaceResourceGroup)
}

module automation 'modes/automation-scheduled.bicep' = if (deploymentMode == 'automation-scheduled') {
  name: 'automation-scheduled'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    emergencyAccessGroupObjectId: emergencyAccessGroupObjectId
    scheduleFrequency: scheduleFrequency
    scheduleInterval: int(scheduleInterval)
    scheduleTimeZone: scheduleTimeZone
    scheduleStartTime: effectiveScheduleStartTime
  }
}

module scheduledFunction 'modes/function-scheduled.bicep' = if (deploymentMode == 'function-scheduled') {
  name: 'function-scheduled'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    emergencyAccessGroupObjectId: emergencyAccessGroupObjectId
    scheduleCron: scheduleCron
  }
}

module scheduledLogicApp 'modes/logicapp-scheduled.bicep' = if (deploymentMode == 'logicapp-scheduled') {
  name: 'logicapp-scheduled'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    emergencyAccessGroupObjectId: emergencyAccessGroupObjectId
    scheduleFrequency: scheduleFrequency
    scheduleInterval: int(scheduleInterval)
    scheduleTimeZone: scheduleTimeZone
  }
}

module sentinelFunction 'modes/sentinel-function.bicep' = if (deploymentMode == 'sentinel-function') {
  name: 'sentinel-function'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    emergencyAccessGroupObjectId: emergencyAccessGroupObjectId
    sentinelWorkspaceName: sentinelWorkspaceName
    sentinelWorkspaceSubscriptionId: sentinelWorkspaceSubscriptionId
    sentinelWorkspaceResourceGroup: sentinelWorkspaceResourceGroup
    sentinelKql: sentinelKql
    functionAuthClientId: functionAuthClientId
    functionAuthAudience: functionAuthAudience
    sentinelServicePrincipalId: sentinelServicePrincipalId
    sentinelAlertRuleId: sentinelAlertRuleId
    sentinelAutomationRuleId: sentinelAutomationRuleId
  }
}

module signInAlerting 'modules/signin-alerting.bicep' = if (enableSignInAlerts == 'true') {
  name: 'signin-alerting'
  params: {
    location: signInLogWorkspace!.location
    namePrefix: namePrefix
    tags: tags
    workspaceResourceId: signInLogWorkspace!.id
    emergencyUser1ObjectId: emergencyUser1ObjectId
    emergencyUser2ObjectId: emergencyUser2ObjectId
    notificationEmail: signInAlertEmail
  }
}

module sentinelActivityAlerting 'modules/sentinel-activity-alerting.bicep' = if (enableSentinelActivityAlerts == 'true') {
  name: 'sentinel-activity-alerting'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    workspaceName: sentinelWorkspaceName
    workspaceSubscriptionId: sentinelWorkspaceSubscriptionId
    workspaceResourceGroup: sentinelWorkspaceResourceGroup
    emergencyUser1ObjectId: emergencyUser1ObjectId
    emergencyUser2ObjectId: emergencyUser2ObjectId
    sentinelServicePrincipalId: sentinelServicePrincipalId
    assignAutomationContributor: deploymentMode != 'sentinel-function'
    teamsWebhookUrl: sentinelTeamsWebhookUrl
    teamsDeliveryMode: sentinelTeamsDeliveryMode
    teamsConnectionResourceId: sentinelTeamsConnectionResourceId
    teamsTeamId: sentinelTeamsTeamId
    teamsChannelId: sentinelTeamsChannelId
    outlookConnectionResourceId: sentinelOutlookConnectionResourceId
    notificationEmail: sentinelNotificationEmail
    signInRuleName: last(split(sentinelSignInRuleId, '/'))
    adminActivityRuleName: last(split(sentinelAdminActivityRuleId, '/'))
    accountChangeRuleName: last(split(sentinelAccountChangeRuleId, '/'))
    automationRuleName: last(split(sentinelNotificationAutomationRuleId, '/'))
  }
}

output AZURE_RESOURCE_GROUP string = resourceGroup().name
output AZURE_WORKLOAD_PRINCIPAL_IDS string = deploymentMode == 'automation-scheduled'
  ? automation!.outputs.workloadPrincipalId
  : deploymentMode == 'function-scheduled'
    ? scheduledFunction!.outputs.workloadPrincipalId
    : deploymentMode == 'logicapp-scheduled'
      ? scheduledLogicApp!.outputs.workloadPrincipalId
      : sentinelFunction!.outputs.workloadPrincipalId
output AZURE_FUNCTION_APP_NAME string = deploymentMode == 'function-scheduled'
  ? scheduledFunction!.outputs.functionAppName
  : deploymentMode == 'sentinel-function'
    ? sentinelFunction!.outputs.functionAppName
    : ''
output AZURE_PLAYBOOK_PRINCIPAL_ID string = deploymentMode == 'sentinel-function' ? sentinelFunction!.outputs.playbookPrincipalId : ''
output AZURE_PLAYBOOK_NAME string = deploymentMode == 'sentinel-function' ? sentinelFunction!.outputs.playbookName : ''
output AZURE_PLAYBOOK_RESOURCE_ID string = deploymentMode == 'sentinel-function' ? sentinelFunction!.outputs.playbookResourceId : ''
output AZURE_SENTINEL_ALERT_RULE_ID string = deploymentMode == 'sentinel-function' ? sentinelFunction!.outputs.alertRuleId : ''
output AZURE_SENTINEL_AUTOMATION_RULE_ID string = deploymentMode == 'sentinel-function' ? sentinelFunction!.outputs.automationRuleId : ''
output AZURE_SIGNIN_ALERT_RULE_ID string = enableSignInAlerts == 'true' ? signInAlerting!.outputs.alertRuleId : ''
output AZURE_SIGNIN_ALERT_ACTION_GROUP_ID string = enableSignInAlerts == 'true' ? signInAlerting!.outputs.actionGroupId : ''
output AZURE_SENTINEL_ACTIVITY_PLAYBOOK_NAME string = enableSentinelActivityAlerts == 'true'
  ? sentinelActivityAlerting!.outputs.playbookName
  : ''
output AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID string = enableSentinelActivityAlerts == 'true'
  ? sentinelActivityAlerting!.outputs.playbookResourceId
  : ''
output AZURE_SENTINEL_ACTIVITY_PLAYBOOK_PRINCIPAL_ID string = enableSentinelActivityAlerts == 'true'
  ? sentinelActivityAlerting!.outputs.playbookPrincipalId
  : ''
output AZURE_SENTINEL_SIGNIN_RULE_ID string = enableSentinelActivityAlerts == 'true'
  ? sentinelActivityAlerting!.outputs.signInRuleId
  : ''
output AZURE_SENTINEL_ADMIN_ACTIVITY_RULE_ID string = enableSentinelActivityAlerts == 'true'
  ? sentinelActivityAlerting!.outputs.adminActivityRuleId
  : ''
output AZURE_SENTINEL_ACCOUNT_CHANGE_RULE_ID string = enableSentinelActivityAlerts == 'true'
  ? sentinelActivityAlerting!.outputs.accountChangeRuleId
  : ''
output AZURE_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID string = enableSentinelActivityAlerts == 'true'
  ? sentinelActivityAlerting!.outputs.automationRuleId
  : ''
output AZURE_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID string = enableSentinelActivityAlerts == 'true'
  ? sentinelActivityAlerting!.outputs.sentinelReaderRoleAssignmentId
  : ''
output AZURE_SENTINEL_TEAMS_CONNECTION_RESOURCE_ID string = enableSentinelActivityAlerts == 'true'
  ? sentinelActivityAlerting!.outputs.teamsConnectionResourceId
  : ''
output AZURE_WORKLOAD_RESOURCE_NAME string = deploymentMode == 'automation-scheduled'
  ? automation!.outputs.workloadResourceName
  : deploymentMode == 'function-scheduled'
    ? scheduledFunction!.outputs.workloadResourceName
    : deploymentMode == 'logicapp-scheduled'
      ? scheduledLogicApp!.outputs.workloadResourceName
      : sentinelFunction!.outputs.workloadResourceName
