param location string
param namePrefix string
param tags object
param emergencyAccessGroupObjectId string
param scheduleCron string

var sanitized = toLower(replace(replace(namePrefix, '-', ''), '_', ''))
var storageName = take('${sanitized}fn${uniqueString(resourceGroup().id)}', 24)
var functionAppName = '${namePrefix}-scheduled-fn'

module identity '../modules/identity.bicep' = {
  name: 'function-identity'
  params: {
    location: location
    name: '${namePrefix}-fn-id'
    tags: tags
  }
}

module observability '../modules/observability.bicep' = {
  name: 'observability'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    appInsightsPrincipalId: identity.outputs.principalId
  }
}

module storage '../modules/storage.bicep' = {
  name: 'function-storage'
  params: {
    location: location
    name: storageName
    principalId: identity.outputs.principalId
    tags: tags
  }
}

module functionApp '../modules/function-flex.bicep' = {
  name: 'scheduled-function'
  params: {
    location: location
    name: functionAppName
    identityId: identity.outputs.id
    identityClientId: identity.outputs.clientId
    identityPrincipalId: identity.outputs.principalId
    storageName: storage.outputs.name
    storageBlobEndpoint: storage.outputs.blobEndpoint
    storageQueueEndpoint: storage.outputs.queueEndpoint
    storageTableEndpoint: storage.outputs.tableEndpoint
    deploymentContainerUrl: storage.outputs.deploymentContainerUrl
    appInsightsConnectionString: observability.outputs.appInsightsConnectionString
    workspaceId: observability.outputs.workspaceId
    authClientId: ''
    authAudience: ''
    appSettings: {
      EMERGENCY_ACCESS_GROUP_OBJECT_ID: emergencyAccessGroupObjectId
      EMERGENCY_ACCESS_SCHEDULE: scheduleCron
      'AzureWebJobs.HttpRemediation.Disabled': true
      'AzureWebJobs.TimerRemediation.Disabled': false
      APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD;ClientId=${identity.outputs.clientId}'
    }
    tags: tags
  }
}

output workloadPrincipalId string = identity.outputs.principalId
output functionAppName string = functionApp.outputs.name
output workloadResourceName string = functionApp.outputs.name
