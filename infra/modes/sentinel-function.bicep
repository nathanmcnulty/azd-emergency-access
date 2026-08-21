param location string
param namePrefix string
param tags object
@minLength(1)
param emergencyAccessGroupObjectId string
param sentinelWorkspaceName string
param sentinelWorkspaceSubscriptionId string
param sentinelWorkspaceResourceGroup string
param sentinelKql string
@minLength(1)
param functionAuthClientId string
@minLength(1)
param functionAuthAudience string
param sentinelServicePrincipalId string
param sentinelAlertRuleId string
param sentinelAutomationRuleId string

var sanitized = toLower(replace(replace(namePrefix, '-', ''), '_', ''))
var storageName = take('${sanitized}sn${uniqueString(resourceGroup().id)}', 24)
var functionAppName = '${namePrefix}-sentinel-fn'
var functionIdentityName = '${namePrefix}-sentinel-fn-id'
var playbookName = '${namePrefix}-sentinel-playbook'
var playbookIdentityName = '${namePrefix}-playbook-id'
var playbookIdentityId = resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', playbookIdentityName)

module functionIdentity '../modules/identity.bicep' = {
  name: 'function-identity'
  params: {
    location: location
    name: functionIdentityName
    tags: tags
  }
}

module playbookIdentity '../modules/identity.bicep' = {
  name: 'playbook-identity'
  params: {
    location: location
    name: playbookIdentityName
    tags: tags
  }
}

module observability '../modules/observability.bicep' = {
  name: 'observability'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    appInsightsPrincipalId: functionIdentity.outputs.principalId
  }
}

module storage '../modules/storage.bicep' = {
  name: 'function-storage'
  params: {
    location: location
    name: storageName
    principalId: functionIdentity.outputs.principalId
    tags: tags
  }
}

module functionApp '../modules/function-flex.bicep' = {
  name: 'sentinel-function-app'
  params: {
    location: location
    name: functionAppName
    identityId: functionIdentity.outputs.id
    identityClientId: functionIdentity.outputs.clientId
    identityPrincipalId: functionIdentity.outputs.principalId
    storageName: storage.outputs.name
    storageBlobEndpoint: storage.outputs.blobEndpoint
    storageQueueEndpoint: storage.outputs.queueEndpoint
    storageTableEndpoint: storage.outputs.tableEndpoint
    deploymentContainerUrl: storage.outputs.deploymentContainerUrl
    appInsightsConnectionString: observability.outputs.appInsightsConnectionString
    workspaceId: observability.outputs.workspaceId
    authClientId: functionAuthClientId
    authAudience: functionAuthAudience
    allowedPrincipalIds: [
      playbookIdentity.outputs.principalId
    ]
    appSettings: {
      EMERGENCY_ACCESS_GROUP_OBJECT_ID: emergencyAccessGroupObjectId
      'AzureWebJobs.HttpRemediation.Disabled': false
      'AzureWebJobs.TimerRemediation.Disabled': true
      APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD;ClientId=${functionIdentity.outputs.clientId}'
    }
    tags: tags
  }
}

resource sentinelConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: '${namePrefix}-sentinel-connection'
  location: location
  tags: tags
  properties: {
    displayName: '${namePrefix} Microsoft Sentinel'
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azuresentinel')
    }
    #disable-next-line BCP037
    parameterValueType: 'Alternative'
  }
}

resource playbook 'Microsoft.Logic/workflows@2019-05-01' = {
  name: playbookName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${playbookIdentityId}': {}
    }
  }
  properties: {
    state: 'Enabled'
    parameters: {
      '$connections': {
        value: {
          azuresentinel: {
            connectionId: sentinelConnection.id
            connectionName: sentinelConnection.name
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
                identity: playbookIdentityId
              }
            }
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azuresentinel')
          }
        }
      }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          type: 'Object'
          defaultValue: {}
        }
      }
      triggers: {
        Microsoft_Sentinel_alert: {
          type: 'ApiConnectionWebhook'
          inputs: {
            body: {
              callback_url: '@{listCallbackUrl()}'
            }
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'azuresentinel\'][\'connectionId\']'
              }
            }
            path: '/subscribe'
          }
        }
      }
      actions: {
        Parse_custom_details: {
          type: 'ParseJson'
          inputs: {
            content: '@triggerBody()?[\'ExtendedProperties\']?[\'Custom Details\']'
            schema: {
              type: 'object'
              properties: {
                CAPolicyId: {
                  type: 'array'
                  items: {
                    type: 'string'
                  }
                }
              }
              required: [
                'CAPolicyId'
              ]
            }
          }
          runAfter: {}
        }
        Invoke_protected_function: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '${functionApp.outputs.url}/api/remediate'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              CAPolicyId: '@string(first(body(\'Parse_custom_details\')?[\'CAPolicyId\']))'
            }
            authentication: {
              type: 'ManagedServiceIdentity'
              identity: playbookIdentityId
              audience: functionAuthAudience
            }
          }
          runAfter: {
            Parse_custom_details: [
              'Succeeded'
            ]
          }
        }
      }
      outputs: {}
    }
  }
}

resource sentinelAutomationContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sentinelServicePrincipalId, 'f4c81013-99ee-4d62-a7ee-b3f1f648599a')
  properties: {
    principalId: sentinelServicePrincipalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'f4c81013-99ee-4d62-a7ee-b3f1f648599a'
    )
    principalType: 'ServicePrincipal'
  }
}

var defaultSentinelKql = join([
  'AuditLogs'
  '| where Result =~ "success"'
  '| where OperationName in ("Add conditional access policy", "Update conditional access policy")'
  '| where Identity != "${functionIdentityName}"'
  '| extend CAPolicyId = tostring(todynamic(TargetResources)[0].id), ActorIdentity = Identity'
  '| where isnotempty(CAPolicyId)'
  '| project TimeGenerated, CAPolicyId, OperationName, ActorIdentity, CorrelationId'
], '\n')
var effectiveSentinelKql = empty(sentinelKql) ? defaultSentinelKql : sentinelKql

module sentinelResources 'sentinel-resources.bicep' = {
  name: 'sentinel-resources'
  scope: resourceGroup(sentinelWorkspaceSubscriptionId, sentinelWorkspaceResourceGroup)
  params: {
    workspaceName: sentinelWorkspaceName
    namePrefix: namePrefix
    kql: effectiveSentinelKql
    playbookId: playbook.id
    tenantId: tenant().tenantId
    alertRuleName: last(split(sentinelAlertRuleId, '/'))
    automationRuleName: last(split(sentinelAutomationRuleId, '/'))
  }
  dependsOn: [
    sentinelAutomationContributor
  ]
}

output workloadPrincipalId string = functionIdentity.outputs.principalId
output workloadResourceName string = functionApp.outputs.name
output functionAppName string = functionApp.outputs.name
output playbookPrincipalId string = playbookIdentity.outputs.principalId
output playbookName string = playbook.name
output playbookResourceId string = playbook.id
output alertRuleId string = sentinelResources.outputs.alertRuleId
output automationRuleId string = sentinelResources.outputs.automationRuleId
