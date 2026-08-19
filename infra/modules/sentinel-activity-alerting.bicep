param location string
param namePrefix string
param tags object = {}
param workspaceName string
param workspaceResourceGroup string
param emergencyUser1ObjectId string
param emergencyUser2ObjectId string
param sentinelServicePrincipalId string
param assignAutomationContributor bool
@secure()
param teamsWebhookUrl string
param outlookConnectionResourceId string = ''
param notificationEmail string = ''
param signInRuleName string
param adminActivityRuleName string
param accountChangeRuleName string
param automationRuleName string

var playbookIdentityName = '${namePrefix}-activity-playbook-id'
var playbookName = '${namePrefix}-activity-playbook'
var playbookIdentityId = resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', playbookIdentityName)
var sentinelManagedApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'azuresentinel')
var outlookManagedApiId = subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
var outlookConnectionName = empty(outlookConnectionResourceId) ? '' : last(split(outlookConnectionResourceId, '/'))

module playbookIdentity 'identity.bicep' = {
  name: 'activity-playbook-identity'
  params: {
    location: location
    name: playbookIdentityName
    tags: tags
  }
}

resource sentinelConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: '${namePrefix}-activity-sentinel'
  location: location
  tags: tags
  properties: {
    displayName: '${namePrefix} Microsoft Sentinel activity notifications'
    api: {
      id: sentinelManagedApiId
    }
    #disable-next-line BCP037
    parameterValueType: 'Alternative'
  }
}

var connections = union(
  {
    azuresentinel: {
      connectionId: sentinelConnection.id
      connectionName: sentinelConnection.name
      connectionProperties: {
        authentication: {
          type: 'ManagedServiceIdentity'
          identity: playbookIdentityId
        }
      }
      id: sentinelManagedApiId
    }
  },
  empty(outlookConnectionResourceId)
    ? {}
    : {
        office365: {
          connectionId: outlookConnectionResourceId
          connectionName: outlookConnectionName
          id: outlookManagedApiId
        }
      }
)

var teamsAction = {
  Post_adaptive_card_to_Teams: {
    type: 'Http'
    inputs: {
      method: 'POST'
      uri: '@parameters(\'teamsWebhookUrl\')'
      headers: {
        'Content-Type': 'application/json'
      }
      body: {
        type: 'message'
        attachments: [
          {
            contentType: 'application/vnd.microsoft.card.adaptive'
            contentUrl: null
            content: {
              '$schema': 'http://adaptivecards.io/schemas/adaptive-card.json'
              type: 'AdaptiveCard'
              version: '1.4'
              body: [
                {
                  type: 'TextBlock'
                  text: '@triggerBody()?[\'object\']?[\'properties\']?[\'title\']'
                  weight: 'Bolder'
                  size: 'Medium'
                  wrap: true
                }
                {
                  type: 'FactSet'
                  facts: [
                    {
                      title: 'Severity'
                      value: '@triggerBody()?[\'object\']?[\'properties\']?[\'severity\']'
                    }
                    {
                      title: 'Created'
                      value: '@triggerBody()?[\'object\']?[\'properties\']?[\'createdTimeUtc\']'
                    }
                    {
                      title: 'Incident'
                      value: '@string(triggerBody()?[\'object\']?[\'properties\']?[\'incidentNumber\'])'
                    }
                  ]
                }
                {
                  type: 'TextBlock'
                  text: '@triggerBody()?[\'object\']?[\'properties\']?[\'description\']'
                  wrap: true
                }
              ]
              actions: [
                {
                  type: 'Action.OpenUrl'
                  title: 'Open incident'
                  url: '@triggerBody()?[\'object\']?[\'properties\']?[\'incidentUrl\']'
                }
              ]
            }
          }
        ]
      }
    }
    runAfter: {}
  }
}

var emailAction = empty(outlookConnectionResourceId)
  ? {}
  : {
      Send_incident_email: {
        type: 'ApiConnection'
        inputs: {
          host: {
            connection: {
              name: '@parameters(\'$connections\')[\'office365\'][\'connectionId\']'
            }
          }
          method: 'post'
          path: '/v2/Mail'
          body: {
            To: notificationEmail
            Subject: '@concat(\'[Emergency access] \', triggerBody()?[\'object\']?[\'properties\']?[\'title\'])'
            Body: '@concat(\'<p><strong>\', triggerBody()?[\'object\']?[\'properties\']?[\'title\'], \'</strong></p><p>Severity: \', triggerBody()?[\'object\']?[\'properties\']?[\'severity\'], \'</p><p>\', triggerBody()?[\'object\']?[\'properties\']?[\'description\'], \'</p><p><a href="\', triggerBody()?[\'object\']?[\'properties\']?[\'incidentUrl\'], \'">Open Microsoft Sentinel incident</a></p>\')'
            Importance: 'High'
          }
        }
        runAfter: {}
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
      teamsWebhookUrl: {
        value: teamsWebhookUrl
      }
      '$connections': {
        value: connections
      }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        teamsWebhookUrl: {
          type: 'SecureString'
        }
        '$connections': {
          type: 'Object'
          defaultValue: {}
        }
      }
      triggers: {
        Microsoft_Sentinel_incident: {
          type: 'ApiConnectionWebhook'
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'azuresentinel\'][\'connectionId\']'
              }
            }
            body: {
              callback_url: '@{listCallbackUrl()}'
            }
            path: '/incident-creation'
          }
        }
      }
      actions: union(teamsAction, emailAction)
      outputs: {}
    }
  }
  dependsOn: [
    playbookIdentity
  ]
}

resource sentinelAutomationContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (assignAutomationContributor) {
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

module activityRules 'sentinel-activity-rules.bicep' = {
  name: 'sentinel-activity-rules'
  scope: resourceGroup(workspaceResourceGroup)
  params: {
    workspaceName: workspaceName
    namePrefix: namePrefix
    emergencyUser1ObjectId: emergencyUser1ObjectId
    emergencyUser2ObjectId: emergencyUser2ObjectId
    playbookId: playbook.id
    playbookPrincipalId: playbookIdentity.outputs.principalId
    tenantId: tenant().tenantId
    signInRuleName: signInRuleName
    adminActivityRuleName: adminActivityRuleName
    accountChangeRuleName: accountChangeRuleName
    automationRuleName: automationRuleName
  }
  dependsOn: [
    sentinelAutomationContributor
  ]
}

output playbookName string = playbook.name
output playbookResourceId string = playbook.id
output playbookPrincipalId string = playbookIdentity.outputs.principalId
output signInRuleId string = activityRules.outputs.signInRuleId
output adminActivityRuleId string = activityRules.outputs.adminActivityRuleId
output accountChangeRuleId string = activityRules.outputs.accountChangeRuleId
output automationRuleId string = activityRules.outputs.automationRuleId
output sentinelReaderRoleAssignmentId string = activityRules.outputs.sentinelReaderRoleAssignmentId
