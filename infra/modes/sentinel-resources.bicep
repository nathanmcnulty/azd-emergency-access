param workspaceName string
param namePrefix string
param kql string
param playbookId string
param tenantId string
param alertRuleName string
param automationRuleName string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource alertRule 'Microsoft.SecurityInsights/alertRules@2024-01-01-preview' = {
  name: alertRuleName
  scope: workspace
  #disable-next-line BCP036
  kind: 'NRT'
  properties: {
    alertDetailsOverride: {
      alertDisplayNameFormat: 'Conditional Access policy change: {{CAPolicyId}}'
      alertDescriptionFormat: 'Conditional Access policy {{CAPolicyId}} changed outside emergency-access remediation.'
    }
    customDetails: {
      CAPolicyId: 'CAPolicyId'
    }
    description: 'Detects Conditional Access policy changes not made by the remediation workload.'
    displayName: '${namePrefix} emergency access policy change'
    enabled: true
    eventGroupingSettings: {
      aggregationKind: 'AlertPerResult'
    }
    incidentConfiguration: {
      createIncident: false
      groupingConfiguration: {
        enabled: false
        lookbackDuration: 'PT5M'
        matchingMethod: 'AllEntities'
        reopenClosedIncident: false
      }
    }
    query: kql
    severity: 'High'
    suppressionDuration: 'PT5H'
    suppressionEnabled: false
    tactics: [
      'DefenseEvasion'
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
    displayName: '${namePrefix} invoke emergency access playbook'
    order: 1
    triggeringLogic: {
      isEnabled: true
      triggersOn: 'Alerts'
      triggersWhen: 'Created'
      conditions: [
        {
          conditionType: 'Property'
          conditionProperties: {
            propertyName: 'AlertAnalyticRuleIds'
            operator: 'Contains'
            propertyValues: [
              alertRule.id
            ]
          }
        }
      ]
    }
  }
}

output alertRuleId string = alertRule.id
output automationRuleId string = automationRule.id
