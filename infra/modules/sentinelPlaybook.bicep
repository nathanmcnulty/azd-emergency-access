@description('Location for the playbook Logic App and its Sentinel connection.')
param location string

@description('Tags applied to all resources in this module.')
param tags object

@description('Name of the Consumption Logic App playbook.')
param logicAppName string

@description('Default hostname of the protected Function App HTTP trigger that performs remediation for the single Conditional Access policy identified in the Sentinel alert.')
param functionHostName string

@description('Entra application (client) ID that protects the Function App HTTP trigger. Used as the OAuth audience when the playbook calls the function with its managed identity.')
param functionAadClientId string

@description('Resource ID of the Log Analytics workspace used for platform diagnostic settings (this template\'s own workspace, not the Sentinel workspace).')
param logAnalyticsWorkspaceId string

var sentinelConnectionName = 'azuresentinel-${logicAppName}'
var functionAudience = 'api://${functionAadClientId}'
var functionUri = 'https://${functionHostName}/api/remediate'

resource sentinelConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: sentinelConnectionName
  location: location
  tags: tags
  properties: any({
    displayName: sentinelConnectionName
    customParameterValues: {}
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azuresentinel')
    }
    parameterValueType: 'Alternative'
  })
}

// Minimal alert-triggered playbook: receives the Sentinel NRT alert, extracts CAPolicyId from the
// alert's custom details, and forwards it to the Entra-protected Function HTTP trigger using the
// playbook's own system-assigned managed identity. No direct Microsoft Graph calls happen here --
// remediation logic lives entirely in the shared module executed by the function.
resource playbook 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        Microsoft_Sentinel_alert: {
          type: 'ApiConnectionWebhook'
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'azuresentinel\'][\'connectionId\']'
              }
            }
            body: {
              callback_url: '@listCallbackUrl()'
            }
            path: '/subscribe'
          }
        }
      }
      actions: {
        Parse_alert_custom_details: {
          runAfter: {}
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
        }
        Invoke_remediation_function: {
          runAfter: {
            Parse_alert_custom_details: [
              'Succeeded'
            ]
          }
          type: 'Http'
          inputs: {
            uri: functionUri
            method: 'POST'
            headers: {
              'Content-Type': 'application/json'
            }
            body: {
              CAPolicyId: '@string(first(body(\'Parse_alert_custom_details\')?[\'CAPolicyId\']))'
            }
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: functionAudience
            }
          }
        }
      }
      outputs: {}
    }
    parameters: {
      '$connections': {
        value: {
          azuresentinel: {
            id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azuresentinel')
            connectionId: sentinelConnection.id
            connectionName: sentinelConnectionName
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
              }
            }
          }
        }
      }
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${logicAppName}'
  scope: playbook
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

output name string = playbook.name
output principalId string = playbook.identity.principalId
output id string = playbook.id
