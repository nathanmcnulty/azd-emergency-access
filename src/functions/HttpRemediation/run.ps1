param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$null = $TriggerMetadata

Import-Module (Join-Path $PSScriptRoot '..\shared\EmergencyAccess.Remediation.psm1') -Force

$policyId = [string]$Request.Body.CAPolicyId
if (-not $policyId) {
    Push-OutputBinding -Name Response -Value @{
        StatusCode = 400
        Headers = @{ 'Content-Type' = 'application/json' }
        Body = '{"error":"CAPolicyId is required."}'
    }
    return
}

try {
    $result = Invoke-EmergencyAccessRemediation `
        -EmergencyAccountsGroupObjectId $env:EMERGENCY_ACCESS_GROUP_OBJECT_ID `
        -CAPolicyId $policyId
    Push-OutputBinding -Name Response -Value @{
        StatusCode = 200
        Headers = @{ 'Content-Type' = 'application/json' }
        Body = $result | ConvertTo-Json -Depth 8 -Compress
    }
}
catch {
    $result = $_.Exception.Data['Result']
    Push-OutputBinding -Name Response -Value @{
        StatusCode = 500
        Headers = @{ 'Content-Type' = 'application/json' }
        Body = if ($result) {
            $result | ConvertTo-Json -Depth 8 -Compress
        } else {
            @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
        }
    }
    throw
}

