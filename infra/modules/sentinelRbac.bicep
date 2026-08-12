@description('Object ID of the Azure Security Insights service principal.')
param sentinelAutomationPrincipalId string

var sentinelAutomationContributorRoleId = 'f4c81013-99ee-4d62-a7ee-b3f1f648599a'

resource sentinelAutomationContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sentinelAutomationPrincipalId, sentinelAutomationContributorRoleId)
  properties: {
    principalId: sentinelAutomationPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', sentinelAutomationContributorRoleId)
  }
}
