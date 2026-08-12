param location string
param namePrefix string
param tags object = {}
param deployApplicationInsights bool = true
param appInsightsPrincipalId string = ''

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-log'
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (deployApplicationInsights) {
  name: '${namePrefix}-appi'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
  }
}

var monitoringMetricsPublisherRoleId = '3913510d-42f4-4e42-8a64-420c390055eb'
resource appInsightsPublisherRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployApplicationInsights && !empty(appInsightsPrincipalId)) {
  name: guid(appInsights!.id, appInsightsPrincipalId, monitoringMetricsPublisherRoleId)
  scope: appInsights
  properties: {
    principalId: appInsightsPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisherRoleId)
  }
}

output workspaceId string = workspace.id
output workspaceCustomerId string = workspace.properties.customerId
output appInsightsId string = deployApplicationInsights ? appInsights!.id : ''
output appInsightsConnectionString string = deployApplicationInsights ? appInsights!.properties.ConnectionString : ''
