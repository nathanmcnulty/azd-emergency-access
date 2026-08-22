param workspaceName string
param namePrefix string
param emergencyUser1ObjectId string
param emergencyUser2ObjectId string
param emergencyUser3ObjectId string = ''
param playbookId string
param playbookPrincipalId string
param tenantId string
param signInRuleName string
param adminActivityRuleName string
param accountChangeRuleName string
param automationRuleName string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

var signInQuery = join(
  [
    'SigninLogs'
    '| where UserId in~ ("${emergencyUser1ObjectId}", "${emergencyUser2ObjectId}", "${emergencyUser3ObjectId}")'
    '| project TimeGenerated, UserPrincipalName, UserId, IPAddress, AppDisplayName, ResourceDisplayName, ResultType, ResultDescription, CorrelationId'
  ],
  '\n'
)

var adminActivityQuery = join(
  [
    'AuditLogs'
    '| extend ActorUserId = tostring(InitiatedBy.user.id), ActorUserPrincipalName = tostring(InitiatedBy.user.userPrincipalName)'
    '| where ActorUserId in~ ("${emergencyUser1ObjectId}", "${emergencyUser2ObjectId}", "${emergencyUser3ObjectId}")'
    '| project TimeGenerated, ActorUserPrincipalName, ActorUserId, OperationName, Category, Result, ResultReason, LoggedByService, CorrelationId'
  ],
  '\n'
)

var accountChangeQuery = join(
  [
    'AuditLogs'
    '| mv-expand TargetResource = TargetResources'
    '| extend TargetUserId = tostring(TargetResource.id), TargetUserPrincipalName = tostring(TargetResource.userPrincipalName)'
    '| where TargetUserId in~ ("${emergencyUser1ObjectId}", "${emergencyUser2ObjectId}", "${emergencyUser3ObjectId}")'
    '| extend ActorUserPrincipalName = coalesce(tostring(InitiatedBy.user.userPrincipalName), tostring(InitiatedBy.app.displayName), Identity)'
    '| project TimeGenerated, TargetUserPrincipalName, TargetUserId, ActorUserPrincipalName, OperationName, Category, Result, ResultReason, LoggedByService, CorrelationId'
  ],
  '\n'
)

resource sentinelReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, playbookPrincipalId, '8d289c81-5878-46d4-8554-54e1e3d8b5cb')
  scope: workspace
  properties: {
    principalId: playbookPrincipalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '8d289c81-5878-46d4-8554-54e1e3d8b5cb'
    )
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    signInRule
    adminActivityRule
    accountChangeRule
  ]
}

resource signInRule 'Microsoft.SecurityInsights/alertRules@2024-01-01-preview' = {
  name: signInRuleName
  scope: workspace
  #disable-next-line BCP036
  kind: 'NRT'
  properties: {
    alertDetailsOverride: {
      alertDisplayNameFormat: 'Emergency access sign-in: {{UserPrincipalName}}'
      alertDescriptionFormat: 'Emergency access account {{UserPrincipalName}} attempted to sign in to {{AppDisplayName}} from {{IPAddress}}.'
    }
    customDetails: {
      App: 'AppDisplayName'
      CorrelationId: 'CorrelationId'
      ResultDescription: 'ResultDescription'
      ResultType: 'ResultType'
    }
    description: 'Detects every successful or failed interactive sign-in by a designated emergency access account.'
    displayName: '${namePrefix} emergency access sign-in'
    enabled: true
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [
          {
            identifier: 'AadUserId'
            columnName: 'UserId'
          }
          {
            identifier: 'FullName'
            columnName: 'UserPrincipalName'
          }
        ]
      }
      {
        entityType: 'IP'
        fieldMappings: [
          {
            identifier: 'Address'
            columnName: 'IPAddress'
          }
        ]
      }
    ]
    eventGroupingSettings: {
      aggregationKind: 'AlertPerResult'
    }
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: false
        lookbackDuration: 'PT5M'
        matchingMethod: 'AllEntities'
        reopenClosedIncident: false
      }
    }
    query: signInQuery
    severity: 'High'
    suppressionDuration: 'PT5H'
    suppressionEnabled: false
    tactics: [
      'InitialAccess'
    ]
    techniques: []
  }
}

resource adminActivityRule 'Microsoft.SecurityInsights/alertRules@2024-01-01-preview' = {
  name: adminActivityRuleName
  scope: workspace
  #disable-next-line BCP036
  kind: 'NRT'
  properties: {
    alertDetailsOverride: {
      alertDisplayNameFormat: 'Emergency access admin activity: {{OperationName}}'
      alertDescriptionFormat: '{{ActorUserPrincipalName}} performed {{OperationName}} with result {{Result}}.'
    }
    customDetails: {
      Category: 'Category'
      CorrelationId: 'CorrelationId'
      LoggedByService: 'LoggedByService'
      Operation: 'OperationName'
      Result: 'Result'
      ResultReason: 'ResultReason'
    }
    description: 'Detects Microsoft Entra audit activity initiated by a designated emergency access account.'
    displayName: '${namePrefix} emergency access admin activity'
    enabled: true
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [
          {
            identifier: 'AadUserId'
            columnName: 'ActorUserId'
          }
          {
            identifier: 'FullName'
            columnName: 'ActorUserPrincipalName'
          }
        ]
      }
    ]
    eventGroupingSettings: {
      aggregationKind: 'AlertPerResult'
    }
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: false
        lookbackDuration: 'PT5M'
        matchingMethod: 'AllEntities'
        reopenClosedIncident: false
      }
    }
    query: adminActivityQuery
    severity: 'High'
    suppressionDuration: 'PT5H'
    suppressionEnabled: false
    tactics: [
      'PrivilegeEscalation'
    ]
    techniques: []
  }
}

resource accountChangeRule 'Microsoft.SecurityInsights/alertRules@2024-01-01-preview' = {
  name: accountChangeRuleName
  scope: workspace
  #disable-next-line BCP036
  kind: 'NRT'
  properties: {
    alertDetailsOverride: {
      alertDisplayNameFormat: 'Emergency access account changed: {{OperationName}}'
      alertDescriptionFormat: '{{ActorUserPrincipalName}} performed {{OperationName}} on emergency account {{TargetUserPrincipalName}}.'
    }
    customDetails: {
      Actor: 'ActorUserPrincipalName'
      Category: 'Category'
      CorrelationId: 'CorrelationId'
      LoggedByService: 'LoggedByService'
      Operation: 'OperationName'
      Result: 'Result'
      ResultReason: 'ResultReason'
    }
    description: 'Detects Microsoft Entra audit events that change a designated emergency access account.'
    displayName: '${namePrefix} emergency access account change'
    enabled: true
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [
          {
            identifier: 'AadUserId'
            columnName: 'TargetUserId'
          }
          {
            identifier: 'FullName'
            columnName: 'TargetUserPrincipalName'
          }
        ]
      }
    ]
    eventGroupingSettings: {
      aggregationKind: 'AlertPerResult'
    }
    incidentConfiguration: {
      createIncident: true
      groupingConfiguration: {
        enabled: false
        lookbackDuration: 'PT5M'
        matchingMethod: 'AllEntities'
        reopenClosedIncident: false
      }
    }
    query: accountChangeQuery
    severity: 'High'
    suppressionDuration: 'PT5H'
    suppressionEnabled: false
    tactics: [
      'Persistence'
    ]
    techniques: []
  }
}

resource automationRule 'Microsoft.SecurityInsights/automationRules@2024-09-01' = {
  name: automationRuleName
  scope: workspace
  properties: {
    actions: [
      {
        actionType: 'RunPlaybook'
        order: 1
        actionConfiguration: {
          logicAppResourceId: playbookId
          tenantId: tenantId
        }
      }
    ]
    displayName: '${namePrefix} notify emergency access activity'
    order: 2
    triggeringLogic: {
      isEnabled: true
      triggersOn: 'Incidents'
      triggersWhen: 'Created'
      conditions: [
        {
          conditionType: 'Property'
          conditionProperties: {
            propertyName: 'IncidentRelatedAnalyticRuleIds'
            operator: 'Contains'
            propertyValues: [
              signInRule.id
              adminActivityRule.id
              accountChangeRule.id
            ]
          }
        }
      ]
    }
  }
  dependsOn: [
    sentinelReader
  ]
}

output signInRuleId string = signInRule.id
output adminActivityRuleId string = adminActivityRule.id
output accountChangeRuleId string = accountChangeRule.id
output automationRuleId string = automationRule.id
output sentinelReaderRoleAssignmentId string = sentinelReader.id
