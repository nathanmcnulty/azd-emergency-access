@description('Location for the Function App and its plan.')
param location string

@description('Tags applied to all resources in this module.')
param tags object

@description('Name of the Function App.')
param functionAppName string

@description('Name of the Flex Consumption (FC1) App Service plan.')
param appServicePlanName string

@description('Name of the storage account used for both the Flex Consumption deployment package and AzureWebJobsStorage. Identity-based access only -- no shared keys.')
param storageAccountName string

@description('Name of the blob container used as the Flex Consumption deployment package location.')
param deploymentContainerName string

@description('Resource ID of the user-assigned managed identity used for storage and Microsoft Graph authentication.')
param userAssignedIdentityResourceId string

@description('Client ID of the user-assigned managed identity.')
param userAssignedIdentityClientId string

@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Resource ID of the Application Insights component used for managed-identity telemetry publishing.')
param appInsightsResourceId string

@description('Resource ID of the Log Analytics workspace used for platform diagnostic settings.')
param logAnalyticsWorkspaceId string

@description('Object ID (GUID) of the Microsoft Entra emergency access security group.')
param emergencyAccessGroupObjectId string

@description('6-field NCronTab schedule for the timer-triggered function (function-scheduled mode only; ignored when the HTTP trigger is used).')
param remediationScheduleCron string

@description('When true, deploys with the Entra-protected HTTP trigger enabled for Sentinel invocation (sentinel-function mode). When false, only the timer trigger is used (function-scheduled mode).')
param enableHttpTrigger bool

@description('Microsoft Entra tenant ID, used to build the Easy Auth V2 OpenID issuer.')
param tenantId string

@description('Entra application (client) ID that represents this function app as an Easy Auth V2 protected resource. Required only when enableHttpTrigger is true.')
param aadClientId string = ''

@description('Object IDs of principals allowed to call the protected HTTP function (for example, the Sentinel playbook managed identity).')
param allowedCallerPrincipalIds array = []

var runtimeName = 'powershell'
var runtimeVersion = '7.4'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

var baseAppSettings = [
  {
    name: 'AzureWebJobsStorage__accountName'
    value: storageAccount.name
  }
  {
    name: 'AzureWebJobsStorage__credential'
    value: 'managedidentity'
  }
  {
    name: 'AzureWebJobsStorage__clientId'
    value: userAssignedIdentityClientId
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsightsConnectionString
  }
  {
    name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
    value: 'ClientId=${userAssignedIdentityClientId};Authorization=AAD'
  }
  {
    name: 'EMERGENCY_ACCESS_GROUP_ID'
    value: emergencyAccessGroupObjectId
  }
  {
    name: 'REMEDIATION_SCHEDULE_CRON'
    value: remediationScheduleCron
  }
  {
    name: 'REMEDIATION_MANAGED_IDENTITY_CLIENT_ID'
    value: userAssignedIdentityClientId
  }
]

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityResourceId}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    keyVaultReferenceIdentity: userAssignedIdentityResourceId
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: userAssignedIdentityResourceId
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40
      }
      runtime: {
        name: runtimeName
        version: runtimeVersion
      }
    }
    siteConfig: {
      appSettings: baseAppSettings
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
    }
  }
}

// Easy Auth V2: only meaningful for the HTTP-triggered sentinel-function mode. The timer-only
// function-scheduled mode has no public HTTP surface to protect, so this is skipped entirely.
resource functionAppAuth 'Microsoft.Web/sites/config@2023-12-01' = if (enableHttpTrigger) {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: aadClientId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            'api://${aadClientId}'
          ]
          defaultAuthorizationPolicy: {
            allowedPrincipals: {
              identities: allowedCallerPrincipalIds
            }
          }
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${functionAppName}'
  scope: functionApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: last(split(appInsightsResourceId, '/'))
}

resource monitoringMetricsPublisherAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, userAssignedIdentityResourceId, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: appInsights
  properties: {
    principalId: reference(userAssignedIdentityResourceId, '2023-01-31', 'Full').properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
  }
}

output name string = functionApp.name
output defaultHostName string = functionApp.properties.defaultHostName
output id string = functionApp.id
