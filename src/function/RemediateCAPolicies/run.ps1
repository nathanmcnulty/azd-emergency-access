<#
.SYNOPSIS
    Timer-triggered Azure Function for AZD_DEPLOYMENT_MODE = function-scheduled.

.DESCRIPTION
    Runs on the schedule configured by the REMEDIATION_SCHEDULE_CRON app setting (a standard
    6-field NCronTab expression). Enumerates every Conditional Access policy in the tenant and
    ensures the emergency access group is excluded from each one, preserving any existing
    exclusions. Delegates all remediation logic to the shared EmergencyAccessRemediation module
    (deployed under ./Modules by scripts/Publish-FunctionApp.ps1) so behavior is identical across
    every deployment mode.

.NOTES
    Authenticates to Microsoft Graph using the function app's user-assigned managed identity.
    Required Microsoft Graph application permissions: Policy.Read.All,
    Policy.ReadWrite.ConditionalAccess.
#>
param(
    [Parameter(Mandatory = $true)]
    $Timer
)

$ErrorActionPreference = 'Stop'

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
if (-not (Get-Command -Name 'Invoke-EmergencyAccessRemediation' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\EmergencyAccessRemediation\EmergencyAccessRemediation.psm1') -Force
}

if ($Timer.IsPastDue) {
    Write-Warning 'RemediateCAPolicies timer trigger is running late.'
}

$groupId = $env:EMERGENCY_ACCESS_GROUP_ID
$clientId = $env:REMEDIATION_MANAGED_IDENTITY_CLIENT_ID

if (-not (Get-MgContext)) {
    if ($clientId) {
        Connect-MgGraph -Identity -ClientId $clientId -NoWelcome
    }
    else {
        Connect-MgGraph -Identity -NoWelcome
    }
}

$result = Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $groupId

Write-Information ($result | ConvertTo-Json -Depth 6) -InformationAction Continue

if (-not $result.succeeded) {
    throw "Failed to update $($result.policiesFailed) Conditional Access policy or policies. See function logs for details."
}
