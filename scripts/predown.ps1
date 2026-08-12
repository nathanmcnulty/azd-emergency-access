#Requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:AZD_DEPLOYMENT_MODE -ne 'sentinel-function') {
    return
}

function Remove-ExternalSentinelResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [string] $ApiVersion
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        throw 'A Sentinel resource ID is missing from the azd environment. Run azd provision once to restore outputs before azd down, or remove the template-owned Sentinel rules manually.'
    }

    $output = & az rest --method delete --uri "https://management.azure.com$ResourceId`?api-version=$ApiVersion" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Deleted external Sentinel resource: $ResourceId" -ForegroundColor Green
        return
    }

    $message = $output -join [Environment]::NewLine
    if ($message -match '(?i)ResourceNotFound|NotFound|404') {
        Write-Host "External Sentinel resource is already absent: $ResourceId"
        return
    }

    throw "Failed to delete external Sentinel resource '$ResourceId'. azd down is stopping to avoid orphaning content in the existing workspace. $message"
}

Write-Host 'Removing template-owned Sentinel content from the external workspace before resource-group teardown...'
Remove-ExternalSentinelResource -ResourceId $env:SENTINEL_AUTOMATION_RULE_ID -ApiVersion '2023-02-01-preview'
Remove-ExternalSentinelResource -ResourceId $env:SENTINEL_ANALYTICS_RULE_ID -ApiVersion '2023-02-01-preview'
