param location string
param namePrefix string
param tags object
@minLength(1)
param emergencyAccessGroupObjectId string
param scheduleFrequency string
param scheduleInterval int
param scheduleTimeZone string

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${namePrefix}-scheduled-la'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Disabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      triggers: {
        Schedule: {
          type: 'Recurrence'
          recurrence: {
            frequency: scheduleFrequency
            interval: scheduleInterval
            timeZone: scheduleTimeZone == 'Etc/UTC' ? 'UTC' : scheduleTimeZone
          }
        }
      }
      actions: {
        Initialize_policies: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'Policies'
                type: 'array'
                value: []
              }
            ]
          }
          runAfter: {}
        }
        Initialize_next_link: {
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
          runAfter: {
            Initialize_policies: [
              'Succeeded'
            ]
          }
        }
        Initialize_patch_failures: {
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'PatchFailures'
                type: 'array'
                value: []
              }
            ]
          }
          runAfter: {
            Initialize_next_link: [
              'Succeeded'
            ]
          }
        }
        Get_all_policy_pages: {
          type: 'Until'
          expression: '@empty(variables(\'NextLink\'))'
          limit: {
            count: 100
            timeout: 'PT1H'
          }
          actions: {
            Get_policy_page: {
              type: 'Http'
              inputs: {
                method: 'GET'
                uri: '@variables(\'NextLink\')'
                authentication: {
                  type: 'ManagedServiceIdentity'
                  audience: 'https://graph.microsoft.com'
                }
              }
              runAfter: {}
            }
            Add_page_policies: {
              type: 'Foreach'
              foreach: '@body(\'Get_policy_page\')?[\'value\']'
              operationOptions: 'Sequential'
              actions: {
                Add_policy: {
                  type: 'AppendToArrayVariable'
                  inputs: {
                    name: 'Policies'
                    value: '@items(\'Add_page_policies\')'
                  }
                  runAfter: {}
                }
              }
              runAfter: {
                Get_policy_page: [
                  'Succeeded'
                ]
              }
            }
            Set_next_link: {
              type: 'SetVariable'
              inputs: {
                name: 'NextLink'
                value: '@coalesce(body(\'Get_policy_page\')?[\'@odata.nextLink\'], \'\')'
              }
              runAfter: {
                Add_page_policies: [
                  'Succeeded'
                ]
              }
            }
          }
          runAfter: {
            Initialize_patch_failures: [
              'Succeeded'
            ]
          }
        }
        Remediate_each_policy: {
          type: 'Foreach'
          foreach: '@variables(\'Policies\')'
          operationOptions: 'Sequential'
          actions: {
            Group_is_missing: {
              type: 'If'
              expression: {
                and: [
                  {
                    not: {
                      contains: [
                        '@coalesce(items(\'Remediate_each_policy\')?[\'conditions\']?[\'users\']?[\'includeUsers\'], json(\'[]\'))'
                        'None'
                      ]
                    }
                  }
                  {
                    not: {
                      contains: [
                        '@coalesce(items(\'Remediate_each_policy\')?[\'conditions\']?[\'users\']?[\'excludeGroups\'], json(\'[]\'))'
                        emergencyAccessGroupObjectId
                      ]
                    }
                  }
                ]
              }
              actions: {
                Patch_policy: {
                  type: 'Http'
                  inputs: {
                    method: 'PATCH'
                    uri: '@concat(\'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/\', items(\'Remediate_each_policy\')?[\'id\'])'
                    headers: {
                      'Content-Type': 'application/json'
                    }
                    body: {
                      conditions: {
                        users: {
                          excludeGroups: '@union(coalesce(items(\'Remediate_each_policy\')?[\'conditions\']?[\'users\']?[\'excludeGroups\'], json(\'[]\')), array(\'${emergencyAccessGroupObjectId}\'))'
                        }
                      }
                    }
                    authentication: {
                      type: 'ManagedServiceIdentity'
                      audience: 'https://graph.microsoft.com'
                    }
                  }
                  runAfter: {}
                }
                Record_patch_failure: {
                  type: 'AppendToArrayVariable'
                  inputs: {
                    name: 'PatchFailures'
                    value: {
                      policyId: '@items(\'Remediate_each_policy\')?[\'id\']'
                      statusCode: '@outputs(\'Patch_policy\')?[\'statusCode\']'
                      error: '@outputs(\'Patch_policy\')?[\'body\']?[\'error\']'
                    }
                  }
                  runAfter: {
                    Patch_policy: [
                      'Failed'
                      'TimedOut'
                    ]
                  }
                }
              }
              else: {
                actions: {}
              }
              runAfter: {}
            }
          }
          runAfter: {
            Get_all_policy_pages: [
              'Succeeded'
            ]
          }
        }
        Fail_if_patch_failed: {
          type: 'If'
          expression: '@greater(length(variables(\'PatchFailures\')), 0)'
          actions: {
            Terminate_with_patch_failures: {
              type: 'Terminate'
              inputs: {
                runStatus: 'Failed'
                runError: {
                  code: 'ConditionalAccessPatchFailed'
                  message: '@string(variables(\'PatchFailures\'))'
                }
              }
              runAfter: {}
            }
          }
          else: {
            actions: {}
          }
          runAfter: {
            Remediate_each_policy: [
              'Succeeded'
            ]
          }
        }
      }
      outputs: {}
    }
  }
}

output workloadPrincipalId string = workflow.identity.principalId
output workloadResourceName string = workflow.name
