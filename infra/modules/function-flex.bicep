param location string
param name string
param identityId string
param identityClientId string
param identityPrincipalId string
param storageName string
param storageBlobEndpoint string
param storageQueueEndpoint string
param storageTableEndpoint string
param deploymentContainerUrl string
param appInsightsConnectionString string
param workspaceId string
param authClientId string
param authAudience string
param allowedPrincipalIds array = []
param appSettings object = {}
param tags object = {}

var baseAppSettings = [
  {
    name: 'FUNCTIONS_EXTENSION_VERSION'
    value: '~4'
  }
  {
    name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
    value: appInsightsConnectionString
  }
  {
    name: 'AzureWebJobsStorage__accountName'
    value: storageName
  }
  {
    name: 'AzureWebJobsStorage__blobServiceUri'
    value: storageBlobEndpoint
  }
  {
    name: 'AzureWebJobsStorage__queueServiceUri'
    value: storageQueueEndpoint
  }
  {
    name: 'AzureWebJobsStorage__tableServiceUri'
    value: storageTableEndpoint
  }
  {
    name: 'AzureWebJobsStorage__credential'
    value: 'managedidentity'
  }
  {
    name: 'AzureWebJobsStorage__clientId'
    value: identityClientId
  }
  {
    name: 'MANAGED_IDENTITY_CLIENT_ID'
    value: identityClientId
  }
]
var additionalAppSettings = [for setting in items(appSettings): {
  name: setting.key
  value: string(setting.value)
}]

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${name}-fc'
  location: location
  tags: tags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource app 'Microsoft.Web/sites@2024-04-01' = {
  name: name
  location: location
  tags: union(tags, {
    'azd-service-name': 'api'
  })
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    virtualNetworkSubnetId: null
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: deploymentContainerUrl
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identityId
          }
        }
      }
      runtime: {
        name: 'powershell'
        version: '7.4'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 20
        instanceMemoryMB: 2048
      }
    }
    siteConfig: {
      alwaysOn: false
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: concat(baseAppSettings, additionalAppSettings)
    }
  }
}

resource auth 'Microsoft.Web/sites/config@2024-04-01' = if (!empty(authClientId)) {
  parent: app
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: authClientId
          openIdIssuer: '${environment().authentication.loginEndpoint}${tenant().tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            authAudience
          ]
          defaultAuthorizationPolicy: empty(allowedPrincipalIds) ? null : {
            allowedPrincipals: {
              identities: allowedPrincipalIds
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
    httpSettings: {
      requireHttps: true
      routes: {
        apiPrefix: '/.auth'
      }
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: app
  properties: {
    workspaceId: workspaceId
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

output id string = app.id
output name string = app.name
output principalId string = identityPrincipalId
output url string = 'https://${app.properties.defaultHostName}'
