@description('Location for the Log Analytics workspace and Application Insights component.')
param location string

@description('Tags applied to all resources in this module.')
param tags object

@description('Name of the operational Log Analytics workspace used for diagnostic settings. This is a dedicated workspace for this template\'s own resources -- it is never the Sentinel-enabled workspace referenced by sentinel-function mode.')
param logAnalyticsWorkspaceName string

@description('Name of the Application Insights component. Pass an empty string to skip creating Application Insights (non-function modes).')
param appInsightsName string = ''

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      disableLocalAuth: false
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = if (!empty(appInsightsName)) {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
output logAnalyticsWorkspaceName string = logAnalyticsWorkspace.name
output appInsightsConnectionString string = !empty(appInsightsName) ? (appInsights.?properties.?ConnectionString ?? '') : ''
output appInsightsName string = !empty(appInsightsName) ? (appInsights.?name ?? '') : ''
output appInsightsResourceId string = !empty(appInsightsName) ? (appInsights.?id ?? '') : ''
