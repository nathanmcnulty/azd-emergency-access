param location string
param namePrefix string
param tags object = {}
param workspaceResourceId string
@minLength(1)
param emergencyUser1ObjectId string
@minLength(1)
param emergencyUser2ObjectId string
param emergencyUser3ObjectId string = ''
param notificationEmail string

var signInQuery = join([
  'SigninLogs'
  '| where ingestion_time() >= ago(5m)'
  '| where UserId in~ ("${emergencyUser1ObjectId}", "${emergencyUser2ObjectId}", "${emergencyUser3ObjectId}")'
  '| project TimeGenerated, UserPrincipalName, UserId, IPAddress, AppDisplayName, ResourceDisplayName, ResultType, ResultDescription, CorrelationId'
], '\n')

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${namePrefix}-emergency-signin-ag'
  location: 'global'
  tags: tags
  properties: {
    enabled: true
    groupShortName: 'EmergSignin'
    emailReceivers: [
      {
        name: 'Emergency access administrators'
        emailAddress: notificationEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource signInAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: '${namePrefix}-emergency-signin'
  location: location
  tags: tags
  properties: {
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
    autoMitigate: false
    criteria: {
      allOf: [
        {
          query: signInQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            minFailingPeriodsToAlert: 1
            numberOfEvaluationPeriods: 1
          }
        }
      ]
    }
    description: 'Critical alert for any successful or failed sign-in attempt by a designated emergency access account.'
    displayName: '${namePrefix} emergency access account sign-in'
    enabled: true
    evaluationFrequency: 'PT5M'
    overrideQueryTimeRange: 'PT1H'
    scopes: [
      workspaceResourceId
    ]
    severity: 0
    skipQueryValidation: false
    windowSize: 'PT5M'
  }
}

output actionGroupId string = actionGroup.id
output alertRuleId string = signInAlert.id
