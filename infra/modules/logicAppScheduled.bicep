@description('Location for the Logic App.')
param location string

@description('Tags applied to the Logic App.')
param tags object

@description('Name of the Consumption Logic App.')
param logicAppName string

@description('Recurrence interval, in minutes, for the scheduled trigger.')
param recurrenceIntervalMinutes int = 15

@description('Object ID (GUID) of the Microsoft Entra emergency access security group.')
param emergencyAccessGroupObjectId string

@description('Resource ID of the Log Analytics workspace used for platform diagnostic settings.')
param logAnalyticsWorkspaceId string

// Consumption Logic App with a system-assigned managed identity. On each recurrence it enumerates
// every Conditional Access policy via Microsoft Graph and adds the emergency access group to
// conditions.users.excludeGroups wherever it is missing, preserving every other exclusion.
resource logicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: empty(emergencyAccessGroupObjectId) ? 'Disabled' : 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        EmergencyAccountsGroupObjectId: {
          defaultValue: emergencyAccessGroupObjectId
          type: 'String'
        }
      }
      triggers: {
        Recurrence: {
          recurrence: {
            interval: recurrenceIntervalMinutes
            frequency: 'Minute'
          }
          type: 'Recurrence'
        }
      }
      actions: {
        Initialize_next_link: {
          runAfter: {}
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'NextLink'
                type: 'string'
                value: 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
              }
            ]
          }
        }
        Process_all_pages: {
          runAfter: {
            Initialize_next_link: [
              'Succeeded'
            ]
          }
          type: 'Until'
          expression: '@empty(variables(\'NextLink\'))'
          limit: {
            count: 1000
            timeout: 'PT1H'
          }
          actions: {
            Get_policy_page: {
              runAfter: {}
              type: 'Http'
              inputs: {
                uri: '@variables(\'NextLink\')'
                method: 'GET'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: 'https://graph.microsoft.com'
                }
              }
            }
            For_each_policy_on_page: {
              foreach: '@body(\'Get_policy_page\')?[\'value\']'
              runAfter: {
                Get_policy_page: [
                  'Succeeded'
                ]
              }
              type: 'Foreach'
              actions: {
                Check_for_exclusion: {
                  actions: {}
                  else: {
                    actions: {
                      Exclude_emergency_access_group: {
                        type: 'Http'
                        inputs: {
                          uri: 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/@{items(\'For_each_policy_on_page\')?[\'id\']}'
                          method: 'PATCH'
                          headers: {
                            'Content-Type': 'application/json'
                          }
                          body: {
                            conditions: {
                              users: {
                                excludeGroups: '@union(array(parameters(\'EmergencyAccountsGroupObjectId\')),coalesce(items(\'For_each_policy_on_page\')?[\'conditions\']?[\'users\']?[\'excludeGroups\'], json(\'[]\')))'
                              }
                            }
                          }
                          authentication: {
                            type: 'ManagedServiceIdentity'
                            audience: 'https://graph.microsoft.com'
                          }
                        }
                      }
                    }
                  }
                  expression: {
                    and: [
                      {
                        contains: [
                          '@coalesce(items(\'For_each_policy_on_page\')?[\'conditions\']?[\'users\']?[\'excludeGroups\'], json(\'[]\'))'
                          '@parameters(\'EmergencyAccountsGroupObjectId\')'
                        ]
                      }
                    ]
                  }
                  type: 'If'
                }
              }
            }
            Set_next_link: {
              runAfter: {
                For_each_policy_on_page: [
                  'Succeeded'
                ]
              }
              type: 'SetVariable'
              inputs: {
                name: 'NextLink'
                value: '@coalesce(body(\'Get_policy_page\')?[\'@odata.nextLink\'], \'\')'
              }
            }
          }
        }
      }
      outputs: {}
    }
    parameters: {}
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${logicAppName}'
  scope: logicApp
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

output name string = logicApp.name
output principalId string = logicApp.identity.principalId
output id string = logicApp.id
