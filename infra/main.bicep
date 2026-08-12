targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment. Used to derive resource names and as a resource tag.')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources created by this template.')
param location string = 'eastus2'

@allowed([
  'automation-scheduled'
  'function-scheduled'
  'logicapp-scheduled'
  'sentinel-function'
])
@description('Selects exactly one remediation implementation to deploy for this environment.')
param deploymentMode string

@description('Name of the resource group that will contain the deployment-mode resources. Defaults to rg-<environmentName>.')
param resourceGroupName string = 'rg-${environmentName}'

@description('Object ID (GUID) of the Microsoft Entra emergency access security group. May be blank at provision time; scripts/postprovision.ps1 resolves/creates the group and patches deployed resources afterward.')
param emergencyAccessGroupObjectId string = ''

@description('6-field NCronTab schedule for the function-scheduled timer trigger and as the informational default for other scheduled modes. Default: every 15 minutes.')
param remediationScheduleCron string = '0 */15 * * * *'

@description('Recurrence interval, in minutes, for the logicapp-scheduled Consumption workflow.')
param logicAppRecurrenceMinutes int = 15

@description('Recurrence interval, in hours, for the automation-scheduled runbook schedule.')
param automationRecurrenceHours int = 1

@description('Entra application (client) ID used to protect the sentinel-function HTTP trigger with Easy Auth V2. Created idempotently by scripts/preprovision.ps1 before this deployment runs. Required only for sentinel-function mode.')
param functionAadClientId string = ''

@description('Object IDs of the principals (for example, the Sentinel playbook managed identity) allowed to call the protected HTTP function. Left empty at first deploy; scripts/postprovision.ps1 patches this after the playbook identity exists.')
param allowedCallerPrincipalIds array = []

@description('Name of the existing Sentinel-enabled Log Analytics workspace. Required only for sentinel-function mode.')
param sentinelWorkspaceName string = ''

@description('Name of the resource group containing the existing Sentinel-enabled Log Analytics workspace. Required only for sentinel-function mode.')
param sentinelWorkspaceResourceGroup string = ''

@description('Subscription ID containing the existing Sentinel-enabled Log Analytics workspace. Defaults to the current subscription.')
param sentinelWorkspaceSubscriptionId string = subscription().subscriptionId

@description('Object ID of the Azure Security Insights service principal used by Sentinel automation. Resolved by preprovision for sentinel-function mode.')
param sentinelAutomationPrincipalId string = ''

var isAutomation = deploymentMode == 'automation-scheduled'
var isFunctionScheduled = deploymentMode == 'function-scheduled'
var isLogicAppScheduled = deploymentMode == 'logicapp-scheduled'
var isSentinelFunction = deploymentMode == 'sentinel-function'
var usesFunction = isFunctionScheduled || isSentinelFunction

var tags = {
  'azd-env-name': environmentName
  'azd-template': 'azd-emergency-access'
  'azd-deployment-mode': deploymentMode
}

resource rg 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

var resourceToken = toLower(uniqueString(subscription().subscriptionId, rg.id, environmentName))

// ---------------------------------------------------------------------------
// Shared operational monitoring (no scheduled query alerts, no Key Vault).
// ---------------------------------------------------------------------------
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    tags: tags
    logAnalyticsWorkspaceName: 'log-${environmentName}-${resourceToken}'
    appInsightsName: usesFunction ? 'appi-${environmentName}-${resourceToken}' : ''
  }
}

// ---------------------------------------------------------------------------
// User-assigned managed identity + identity-based storage (Function modes only).
// ---------------------------------------------------------------------------
module identity 'modules/identity.bicep' = if (usesFunction) {
  name: 'identity'
  scope: rg
  params: {
    location: location
    tags: tags
    identityName: 'id-${environmentName}-${resourceToken}'
  }
}

module storage 'modules/storage.bicep' = if (usesFunction) {
  name: 'storage'
  scope: rg
  params: {
    location: location
    tags: tags
    storageAccountName: take('st${replace(environmentName, '-', '')}${resourceToken}', 24)
    deploymentContainerName: 'app-package'
    userAssignedIdentityPrincipalId: identity.?outputs.?principalId ?? ''
  }
}

// ---------------------------------------------------------------------------
// Azure Functions Flex Consumption (function-scheduled, sentinel-function).
// ---------------------------------------------------------------------------
module functionApp 'modules/function.bicep' = if (usesFunction) {
  name: 'functionApp'
  scope: rg
  params: {
    location: location
    tags: tags
    functionAppName: 'func-${environmentName}-${resourceToken}'
    appServicePlanName: 'plan-${environmentName}-${resourceToken}'
    storageAccountName: storage.?outputs.?name ?? ''
    deploymentContainerName: 'app-package'
    userAssignedIdentityResourceId: identity.?outputs.?id ?? ''
    userAssignedIdentityClientId: identity.?outputs.?clientId ?? ''
    appInsightsConnectionString: monitoring.?outputs.?appInsightsConnectionString ?? ''
    appInsightsResourceId: monitoring.?outputs.?appInsightsResourceId ?? ''
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    emergencyAccessGroupObjectId: emergencyAccessGroupObjectId
    remediationScheduleCron: remediationScheduleCron
    enableHttpTrigger: isSentinelFunction
    tenantId: subscription().tenantId
    aadClientId: functionAadClientId
    allowedCallerPrincipalIds: allowedCallerPrincipalIds
  }
}

// ---------------------------------------------------------------------------
// Azure Automation account + runbook (automation-scheduled).
// ---------------------------------------------------------------------------
module automation 'modules/automation.bicep' = if (isAutomation) {
  name: 'automation'
  scope: rg
  params: {
    location: location
    tags: tags
    automationAccountName: 'aa-${environmentName}-${resourceToken}'
    runbookName: 'Invoke-EmergencyAccessRemediation'
    scheduleRecurrenceHours: automationRecurrenceHours
    emergencyAccessGroupObjectId: emergencyAccessGroupObjectId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

// ---------------------------------------------------------------------------
// Scheduled Consumption Logic App (logicapp-scheduled).
// ---------------------------------------------------------------------------
module logicAppScheduled 'modules/logicAppScheduled.bicep' = if (isLogicAppScheduled) {
  name: 'logicAppScheduled'
  scope: rg
  params: {
    location: location
    tags: tags
    logicAppName: 'logic-${environmentName}-${resourceToken}'
    recurrenceIntervalMinutes: logicAppRecurrenceMinutes
    emergencyAccessGroupObjectId: emergencyAccessGroupObjectId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

// ---------------------------------------------------------------------------
// Sentinel alert-triggered playbook (sentinel-function).
// ---------------------------------------------------------------------------
module sentinelPlaybook 'modules/sentinelPlaybook.bicep' = if (isSentinelFunction) {
  name: 'sentinelPlaybook'
  scope: rg
  params: {
    location: location
    tags: tags
    logicAppName: 'logic-sentinel-${environmentName}-${resourceToken}'
    functionHostName: functionApp.?outputs.?defaultHostName ?? ''
    functionAadClientId: functionAadClientId
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module sentinelAutomationContributor 'modules/sentinelRbac.bicep' = if (isSentinelFunction && !empty(sentinelAutomationPrincipalId)) {
  name: 'sentinelAutomationContributor'
  scope: rg
  params: {
    sentinelAutomationPrincipalId: sentinelAutomationPrincipalId
  }
}

// ---------------------------------------------------------------------------
// Sentinel detection content (NRT rule + automation rule) deployed into the
// resource group that contains the existing Sentinel-enabled workspace, which
// may be a different resource group (and even a different subscription) than
// this template's own resource group.
// ---------------------------------------------------------------------------
module sentinelContent 'modules/sentinelContent.bicep' = if (isSentinelFunction) {
  name: 'sentinelContent'
  scope: resourceGroup(sentinelWorkspaceSubscriptionId, sentinelWorkspaceResourceGroup)
  params: {
    workspaceName: sentinelWorkspaceName
    playbookResourceId: sentinelPlaybook.?outputs.?id ?? ''
    remediationIdentityName: identity.?outputs.?name ?? ''
    tenantId: subscription().tenantId
  }
  dependsOn: [
    sentinelAutomationContributor
  ]
}

output AZD_DEPLOYMENT_MODE string = deploymentMode
output RESOURCE_GROUP_NAME string = rg.name
output AZURE_LOCATION string = location
output EMERGENCY_ACCESS_GROUP_OBJECT_ID string = emergencyAccessGroupObjectId
output FUNCTION_APP_NAME string = functionApp.?outputs.?name ?? ''
output FUNCTION_APP_DEFAULT_HOSTNAME string = functionApp.?outputs.?defaultHostName ?? ''
output FUNCTION_APP_IDENTITY_PRINCIPAL_ID string = identity.?outputs.?principalId ?? ''
output FUNCTION_APP_IDENTITY_CLIENT_ID string = identity.?outputs.?clientId ?? ''
output AUTOMATION_ACCOUNT_NAME string = automation.?outputs.?name ?? ''
output AUTOMATION_ACCOUNT_PRINCIPAL_ID string = automation.?outputs.?principalId ?? ''
output LOGIC_APP_SCHEDULED_NAME string = logicAppScheduled.?outputs.?name ?? ''
output LOGIC_APP_SCHEDULED_PRINCIPAL_ID string = logicAppScheduled.?outputs.?principalId ?? ''
output SENTINEL_PLAYBOOK_NAME string = sentinelPlaybook.?outputs.?name ?? ''
output SENTINEL_PLAYBOOK_PRINCIPAL_ID string = sentinelPlaybook.?outputs.?principalId ?? ''
output SENTINEL_ANALYTICS_RULE_ID string = sentinelContent.?outputs.?analyticsRuleResourceId ?? ''
output SENTINEL_AUTOMATION_RULE_ID string = sentinelContent.?outputs.?automationRuleResourceId ?? ''
