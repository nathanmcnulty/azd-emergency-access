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
param signInLogWorkspaceResourceGroup string = ''
param signInAlertEmail string = ''
param emergencyUser1ObjectId string = ''
param emergencyUser2ObjectId string = ''
var effectiveScheduleStartTime = empty(scheduleStartTime)
  ? generatedScheduleStartTime
  : scheduleStartTime

resource signInLogWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = if (enableSignInAlerts == 'true') {
  name: signInLogWorkspaceName
  scope: resourceGroup(signInLogWorkspaceResourceGroup)
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
output AZURE_WORKLOAD_RESOURCE_NAME string = deploymentMode == 'automation-scheduled'
  ? automation!.outputs.workloadResourceName
  : deploymentMode == 'function-scheduled'
    ? scheduledFunction!.outputs.workloadResourceName
    : deploymentMode == 'logicapp-scheduled'
      ? scheduledLogicApp!.outputs.workloadResourceName
      : sentinelFunction!.outputs.workloadResourceName
