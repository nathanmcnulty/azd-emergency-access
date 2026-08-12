param location string
param namePrefix string
param tags object
param emergencyAccessGroupObjectId string
param scheduleFrequency string
param scheduleInterval int
param scheduleTimeZone string
param scheduleStartTime string

module observability '../modules/observability.bicep' = {
  name: 'observability'
  params: {
    location: location
    namePrefix: namePrefix
    tags: tags
    deployApplicationInsights: false
  }
}

resource automation 'Microsoft.Automation/automationAccounts@2024-10-23' = {
  name: '${namePrefix}-aa'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    disableLocalAuth: true
    encryption: {
      keySource: 'Microsoft.Automation'
    }
    publicNetworkAccess: true
    sku: {
      name: 'Basic'
    }
  }
}

resource runtime 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: automation
  name: 'PowerShell-7-4'
  location: location
  tags: tags
  properties: {
    description: 'PowerShell 7.4 with the supported Az package for managed identity authentication.'
    runtime: {
      language: 'PowerShell'
      version: '7.4'
    }
    defaultPackages: {
      Az: '12.3.0'
    }
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  parent: automation
  name: 'Maintain-EmergencyAccessExclusions'
  location: location
  tags: tags
  properties: {
    description: 'Enumerates Conditional Access policies and preserves/deduplicates emergency group exclusions.'
    logProgress: true
    logVerbose: true
    runbookType: 'PowerShell'
    runtimeEnvironment: runtime.name
  }
}

var runbookScript = '''
param(
  [Parameter(Mandatory = $true)]
  [string] $EmergencyAccessGroupObjectId
)

$ErrorActionPreference = 'Stop'
$graphRoot = 'https://graph.microsoft.com/v1.0'
Disable-AzContextAutosave -Scope Process
$context = (Connect-AzAccount -Identity).Context
$token = (Get-AzAccessToken -ResourceUrl 'https://graph.microsoft.com' -TenantId $context.Tenant.Id).Token
if ($token -is [System.Security.SecureString]) {
  $token = [System.Net.NetworkCredential]::new('', $token).Password
}
$headers = @{
  Authorization = [string]::Concat('Bearer', [char]32, $token)
  'Content-Type' = 'application/json'
}

$policies = [System.Collections.Generic.List[object]]::new()
$nextLink = "$graphRoot/identity/conditionalAccess/policies"
while ($nextLink) {
  $page = Invoke-RestMethod -Method Get -Uri $nextLink -Headers $headers
  foreach ($policy in @($page.value)) {
    $policies.Add($policy)
  }
  $nextLink = $page.'@odata.nextLink'
}

$results = foreach ($policy in $policies) {
  $existing = @($policy.conditions.users.excludeGroups | Where-Object { $_ })
  $merged = @($existing + $EmergencyAccessGroupObjectId | Sort-Object -Unique)
  $missing = $EmergencyAccessGroupObjectId -notin $existing

  if ($missing) {
    $body = @{
      conditions = @{
        users = @{
          excludeGroups = $merged
        }
      }
    } | ConvertTo-Json -Depth 10
    try {
      Invoke-RestMethod `
        -Method Patch `
        -Uri "$graphRoot/identity/conditionalAccess/policies/$($policy.id)" `
        -Headers $headers `
        -Body $body | Out-Null
    }
    catch {
      [pscustomobject]@{
        policyId = $policy.id
        displayName = $policy.displayName
        status = 'Failed'
        previousExcludeGroups = $existing
        excludeGroups = $merged
        error = $_.Exception.Message
      }
      continue
    }
  }

  [pscustomobject]@{
    policyId = $policy.id
    displayName = $policy.displayName
    status = if ($missing) { 'Updated' } else { 'AlreadyExcluded' }
    previousExcludeGroups = $existing
    excludeGroups = $merged
  }
}

$summary = [pscustomobject]@{
  policyCount = $policies.Count
  updatedCount = @($results | Where-Object status -eq 'Updated').Count
  failedCount = @($results | Where-Object status -eq 'Failed').Count
  results = @($results)
}
$summaryJson = $summary | ConvertTo-Json -Depth 30
$summaryJson
if ($summary.failedCount -gt 0) {
  throw "One or more Conditional Access policies failed remediation. Result: $summaryJson"
}
'''

var publisherIdentityName = '${namePrefix}-runbook-publisher-id'
var publisherIdentityId = resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', publisherIdentityName)
module publisherIdentity '../modules/identity.bicep' = {
  name: 'runbook-publisher-identity'
  params: {
    location: location
    name: publisherIdentityName
    tags: tags
  }
}

var automationContributorRoleId = 'f353d9bd-d4a6-484e-a77a-8050b599b867'
resource publisherRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(automation.id, publisherIdentityId, automationContributorRoleId)
  scope: automation
  properties: {
    principalId: publisherIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', automationContributorRoleId)
  }
}

resource publishRunbook 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${namePrefix}-publish-runbook'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${publisherIdentityId}': {}
    }
  }
  properties: {
    azPowerShellVersion: '12.0'
    cleanupPreference: 'OnSuccess'
    retentionInterval: 'P1D'
    timeout: 'PT10M'
    forceUpdateTag: uniqueString(runbookScript)
    environmentVariables: [
      {
        name: 'RUNBOOK_CONTENT'
        value: base64(runbookScript)
      }
      {
        name: 'AUTOMATION_ACCOUNT_NAME'
        value: automation.name
      }
      {
        name: 'RESOURCE_GROUP_NAME'
        value: resourceGroup().name
      }
      {
        name: 'RUNBOOK_NAME'
        value: runbook.name
      }
      {
        name: 'RUNBOOK_URL'
        value: runbook.id
      }
      {
        name: 'ARM_ENDPOINT'
        value: environment().resourceManager
      }
    ]
    scriptContent: '''
$ErrorActionPreference = 'Stop'
$armEndpoint = $env:ARM_ENDPOINT.TrimEnd('/')
$token = (Get-AzAccessToken -ResourceUrl $armEndpoint).Token
if ($token -is [Security.SecureString]) {
  $token = [Net.NetworkCredential]::new('', $token).Password
}
$headers = @{ Authorization = "Bearer $token" }
$content = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:RUNBOOK_CONTENT))
Invoke-RestMethod `
  -Method Put `
  -Uri "$armEndpoint$($env:RUNBOOK_URL)/draft/content?api-version=2024-10-23" `
  -Headers $headers `
  -ContentType 'text/plain' `
  -Body $content | Out-Null
Invoke-RestMethod `
  -Method Post `
  -Uri "$armEndpoint$($env:RUNBOOK_URL)/draft/publish?api-version=2015-10-31" `
  -Headers $headers | Out-Null

$published = $false
for ($attempt = 1; $attempt -le 18 -and -not $published; $attempt++) {
  Start-Sleep -Seconds 5
  $current = Invoke-RestMethod `
    -Method Get `
    -Uri "$armEndpoint$($env:RUNBOOK_URL)?api-version=2024-10-23" `
    -Headers $headers
  $published = $current.properties.state -eq 'Published'
}
if (-not $published) {
  throw 'Runbook did not reach Published state within 90 seconds.'
}
$DeploymentScriptOutputs = @{}
'''
  }
  dependsOn: [
    publisherRole
  ]
}

resource schedule 'Microsoft.Automation/automationAccounts/schedules@2024-10-23' = {
  parent: automation
  name: 'emergency-access'
  properties: {
    advancedSchedule: {}
    description: 'Conditional Access emergency group exclusion maintenance.'
    expiryTime: '9999-12-31T23:59:59+00:00'
    frequency: scheduleFrequency
    interval: scheduleInterval
    startTime: scheduleStartTime
    timeZone: scheduleTimeZone
  }
}

resource jobSchedule 'Microsoft.Automation/automationAccounts/jobSchedules@2024-10-23' = {
  parent: automation
  name: guid(automation.id, runbook.name, schedule.name)
  properties: {
    parameters: {
      emergencyAccessGroupObjectId: emergencyAccessGroupObjectId
    }
    runbook: {
      name: runbook.name
    }
    schedule: {
      name: schedule.name
    }
  }
  dependsOn: [
    publishRunbook
  ]
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: automation
  properties: {
    workspaceId: observability.outputs.workspaceId
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

output workloadPrincipalId string = automation.identity.principalId
output workloadResourceName string = automation.name
