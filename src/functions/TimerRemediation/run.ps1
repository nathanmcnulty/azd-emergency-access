param($Timer)

$ErrorActionPreference = 'Stop'
$null = $Timer

Import-Module (Join-Path $PSScriptRoot '..\shared\EmergencyAccess.Remediation.psm1') -Force
$result = Invoke-EmergencyAccessRemediation `
    -EmergencyAccountsGroupObjectId $env:EMERGENCY_ACCESS_GROUP_OBJECT_ID
$result | ConvertTo-Json -Depth 8 -Compress | Write-Information -InformationAction Continue

