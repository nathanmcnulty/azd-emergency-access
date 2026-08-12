@description('Location for the Automation account.')
param location string

@description('Tags applied to all resources in this module.')
param tags object

@description('Name of the Automation account.')
param automationAccountName string

@description('Name of the PowerShell runbook. Content is published separately by scripts/Publish-AutomationRunbook.ps1 because Automation runbooks are deployed as a single script, not through ARM/Bicep.')
param runbookName string

@description('Recurrence interval, in hours, for the runbook schedule.')
param scheduleRecurrenceHours int = 1

@description('Object ID (GUID) of the Microsoft Entra emergency access security group, stored as an Automation variable and passed as the default runbook parameter.')
param emergencyAccessGroupObjectId string

@description('Resource ID of the Log Analytics workspace used for platform diagnostic settings.')
param logAnalyticsWorkspaceId string

@description('Start time for the runbook schedule. utcNow() may only be used in a parameter default, so this is computed here rather than inline in the schedule resource.')
param scheduleStartTime string = dateTimeAdd(utcNow('o'), 'PT15M')

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
    disableLocalAuth: true
  }
}

// Microsoft.Graph.Authentication is the only external dependency: sufficient for app-only
// Connect-MgGraph -Identity and Invoke-MgGraphRequest calls used by the shared remediation logic.
resource graphAuthModule 'Microsoft.Automation/automationAccounts/modules@2023-11-01' = {
  parent: automationAccount
  name: 'Microsoft.Graph.Authentication'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Microsoft.Graph.Authentication'
    }
  }
}

resource emergencyAccessGroupVariable 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = {
  parent: automationAccount
  name: 'EMERGENCY_ACCESS_GROUP_ID'
  properties: {
    value: emergencyAccessGroupObjectId
    isEncrypted: false
    description: 'Object ID of the Microsoft Entra emergency access security group. Kept in sync by scripts/postprovision.ps1.'
  }
}

// Created empty here; scripts/Publish-AutomationRunbook.ps1 uploads and publishes the runbook
// content (the shared remediation module inlined with the automation wrapper script) via
// `az automation runbook replace-content`, which requires no public content-hosting endpoint.
resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: runbookName
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logProgress: false
    logVerbose: false
    description: 'Ensures the emergency access group is excluded from every Conditional Access policy. Published by scripts/Publish-AutomationRunbook.ps1.'
  }
}

resource schedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: '${runbookName}-schedule'
  properties: {
    description: 'Runs the emergency access remediation runbook on a recurring schedule.'
    frequency: 'Hour'
    interval: scheduleRecurrenceHours
    startTime: scheduleStartTime
    timeZone: 'UTC'
  }
}

resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  parent: automationAccount
  name: guid(automationAccount.id, runbook.name, schedule.name)
  properties: {
    runbook: {
      name: runbook.name
    }
    schedule: {
      name: schedule.name
    }
    parameters: {
      EmergencyAccountsGroupObjectId: emergencyAccessGroupObjectId
    }
  }
}

resource diagnosticSettings 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${automationAccountName}'
  scope: automationAccount
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

output name string = automationAccount.name
output principalId string = automationAccount.identity.principalId
output runbookName string = runbook.name
