@description('Name of the existing Sentinel-enabled Log Analytics workspace. This module is deployed scoped to the resource group (and possibly subscription) that already contains this workspace -- it does not create a workspace.')
param workspaceName string

@description('Resource ID of the playbook Logic App that the automation rule invokes when the NRT rule creates an alert.')
param playbookResourceId string

@description('Display name of the Function App user-assigned managed identity that performs Graph remediation. Embedded in the NRT query so remediation changes do not retrigger detection.')
param remediationIdentityName string

@description('Microsoft Entra tenant ID, required by the automation rule\'s RunPlaybook action.')
param tenantId string

@description('Deterministic GUID for the NRT analytics rule, derived from the workspace and playbook so re-running provisioning is idempotent.')
param analyticsRuleId string = guid(workspaceName, remediationIdentityName, 'nrt-analytics-rule')

@description('Deterministic GUID for the automation rule, derived from the workspace and playbook so re-running provisioning is idempotent.')
param automationRuleId string = guid(workspaceName, remediationIdentityName, 'automation-rule')

var query = 'AuditLogs\n| where Result =~ "success"\n| where OperationName in ("Add conditional access policy", "Update conditional access policy")\n| where Identity != "${remediationIdentityName}"\n| extend CAPolicyId = tostring(todynamic(TargetResources)[0].id), ActorIdentity = Identity\n| where isnotempty(CAPolicyId)\n| project TimeGenerated, CAPolicyId, OperationName, ActorIdentity, CorrelationId'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

// Near-real-time rule: fires one alert per changed Conditional Access policy and never creates an
// incident, matching the "no incidents" requirement for this detection.
resource nrtRule 'Microsoft.SecurityInsights/alertRules@2023-02-01-preview' = {
  scope: workspace
  name: analyticsRuleId
  kind: 'NRT'
  properties: {
    displayName: 'Conditional Access policy changed - enforce emergency access exclusion'
    description: 'Detects successful Conditional Access policy creation or modification and exposes the policy ID for remediation. Excludes changes made by the remediation playbook itself.'
    severity: 'Informational'
    enabled: true
    query: query
    suppressionDuration: 'PT5H'
    suppressionEnabled: false
    tactics: []
    techniques: []
    eventGroupingSettings: {
      aggregationKind: 'AlertPerResult'
    }
    incidentConfiguration: {
      createIncident: false
      groupingConfiguration: {
        enabled: false
        reopenClosedIncident: false
        lookbackDuration: 'PT5H'
        matchingMethod: 'AllEntities'
        groupByEntities: []
        groupByAlertDetails: []
        groupByCustomDetails: []
      }
    }
    customDetails: {
      CAPolicyId: 'CAPolicyId'
      OperationName: 'OperationName'
      ActorIdentity: 'ActorIdentity'
      CorrelationId: 'CorrelationId'
    }
    alertDetailsOverride: {
      alertDisplayNameFormat: 'Conditional Access policy changed: {{CAPolicyId}}'
      alertDescriptionFormat: '{{OperationName}} was performed by {{ActorIdentity}}. The emergency access exclusion will be checked.'
    }
  }
}

// Alert-created automation rule invokes the playbook. This is the current (non-deprecated)
// integration path; it replaces the retired direct analytics-rule-to-playbook link.
resource automationRule 'Microsoft.SecurityInsights/automationRules@2023-02-01-preview' = {
  scope: workspace
  name: automationRuleId
  properties: {
    displayName: 'Run emergency access exclusion playbook'
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
              nrtRule.id
            ]
          }
        }
      ]
    }
    actions: [
      {
        order: 1
        actionType: 'RunPlaybook'
        actionConfiguration: {
          tenantId: tenantId
          logicAppResourceId: playbookResourceId
        }
      }
    ]
  }
}

output analyticsRuleResourceId string = nrtRule.id
output automationRuleResourceId string = automationRule.id
