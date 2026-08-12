<#
.SYNOPSIS
    Azure Automation runbook entry point for the azd-emergency-access template
    (AZD_DEPLOYMENT_MODE = automation-scheduled).

.DESCRIPTION
    Runs on a schedule via the Automation account's system-assigned managed identity. Enumerates
    every Conditional Access policy in the tenant and ensures the emergency access group is
    excluded from each one, preserving any existing exclusions. Delegates all remediation logic
    to the shared EmergencyAccessRemediation module so behavior is identical across every
    deployment mode.

.PARAMETER EmergencyAccountsGroupObjectId
    Object ID (GUID) of the Microsoft Entra emergency access security group. Defaults to the
    EMERGENCY_ACCESS_GROUP_ID Automation variable when not supplied directly.

.NOTES
    Required PowerShell module: Microsoft.Graph.Authentication (imported into the Automation
    account by infra/modules/automation.bicep).
    Required Microsoft Graph application permissions on the Automation account's managed
    identity: Policy.Read.All, Policy.ReadWrite.ConditionalAccess.

    Azure Automation runbooks are published as a single script. scripts/Publish-AutomationRunbook.ps1
    generates the deployed runbook by concatenating src/shared/EmergencyAccessRemediation.psm1
    with this wrapper so the Automation account always runs the exact same reusable logic that is
    covered by tests/EmergencyAccessRemediation.Tests.ps1, with a single source of truth and no
    behavioral drift. When this script runs locally (for example under Pester or manual testing)
    it imports the shared module the normal way instead.
#>
param(
    [Parameter(Mandatory = $false)]
    [string] $EmergencyAccountsGroupObjectId
)

$ErrorActionPreference = 'Stop'

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# When published to Azure Automation, Publish-AutomationRunbook.ps1 inlines the shared module's
# functions directly above this line, so Invoke-EmergencyAccessRemediation is already defined and
# this import is skipped (the relative shared folder does not exist in the runbook sandbox).
if (-not (Get-Command -Name 'Invoke-EmergencyAccessRemediation' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\shared\EmergencyAccessRemediation.psm1') -Force
}

if ([string]::IsNullOrWhiteSpace($EmergencyAccountsGroupObjectId)) {
    $EmergencyAccountsGroupObjectId = Get-AutomationVariable -Name 'EMERGENCY_ACCESS_GROUP_ID'
}

Connect-MgGraph -Identity -NoWelcome

$result = Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $EmergencyAccountsGroupObjectId

Write-Output ($result | ConvertTo-Json -Depth 6)

if (-not $result.succeeded) {
    throw "Failed to update $($result.policiesFailed) Conditional Access policy or policies. See job output for details."
}
