#Requires -Version 7.0
<#
.SYNOPSIS
    Builds and deploys the Function App package for function-scheduled and sentinel-function modes.

.DESCRIPTION
    azure.yaml intentionally has no `services:` block (azd cannot conditionally skip a service's
    deploy stage per AZD_DEPLOYMENT_MODE, and automation-scheduled/logicapp-scheduled modes provision
    no Function App to deploy to). This script is the "secure deploy hook" fallback: it stages the
    src/function folder into a temporary build directory, copies the shared remediation module in
    from src/shared (kept as a single source of truth rather than a duplicated copy committed under
    src/function), zips the result, and deploys it to the already-provisioned Flex Consumption
    Function App using the standard `az functionapp deployment source config-zip` control-plane path
    (over HTTPS with the deployer's own `az` credentials -- no publish profile, function key, or
    storage account key is ever used).

    Called from scripts/postprovision.ps1 for function-scheduled and sentinel-function modes. Safe
    to re-run; it always deploys the current contents of src/function.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string] $FunctionAppName,

    [Parameter(Mandatory = $true)]
    [ValidateSet('function-scheduled', 'sentinel-function')]
    [string] $DeploymentMode
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($FunctionAppName)) {
    Write-Warning 'ResourceGroupName or FunctionAppName is empty; skipping Function App deployment. This is expected if AZD_DEPLOYMENT_MODE has no Function App.'
    return
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$functionSourcePath = Join-Path $repoRoot 'src\function'
$sharedModulePath = Join-Path $repoRoot 'src\shared\EmergencyAccessRemediation.psm1'

if (-not (Test-Path $functionSourcePath)) { throw "Function source not found at $functionSourcePath" }
if (-not (Test-Path $sharedModulePath)) { throw "Shared module not found at $sharedModulePath" }

Write-Host "Building Function App package for '$FunctionAppName'..."

$buildRoot = Join-Path ([System.IO.Path]::GetTempPath()) "azd-emergency-access-func-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$zipPath = $null

try {
    foreach ($item in Get-ChildItem -Path $functionSourcePath -Force) {
        Copy-Item -Path $item.FullName -Destination $buildRoot -Recurse -Force
    }

    foreach ($relativePath in @('.git', '.vscode', 'local.settings.json', 'tests', 'test', '.venv', '__pycache__')) {
        $candidate = Join-Path $buildRoot $relativePath
        if (Test-Path $candidate) {
            Remove-Item -Path $candidate -Recurse -Force
        }
    }
    Get-ChildItem -Path $buildRoot -Recurse -Filter '*.Tests.ps1' | Remove-Item -Force

    $excludedTrigger = if ($DeploymentMode -eq 'function-scheduled') { 'HttpRemediateCAPolicy' } else { 'RemediateCAPolicies' }
    Remove-Item -Path (Join-Path $buildRoot $excludedTrigger) -Recurse -Force

    # Copy the shared remediation module in as its own module folder so `Import-Module
    # EmergencyAccessRemediation` resolves via PSModulePath convention (folder name == module name).
    $modulesDestination = Join-Path $buildRoot 'Modules\EmergencyAccessRemediation'
    New-Item -ItemType Directory -Path $modulesDestination -Force | Out-Null
    Copy-Item -Path $sharedModulePath -Destination (Join-Path $modulesDestination 'EmergencyAccessRemediation.psm1') -Force

    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "azd-emergency-access-func-$([Guid]::NewGuid().ToString('N')).zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    Compress-Archive -Path (Join-Path $buildRoot '*') -DestinationPath $zipPath -Force

    Write-Host "Deploying package to Function App '$FunctionAppName' (resource group '$ResourceGroupName')..."
    # `az functionapp deploy` (the current "one-deploy" API) is used instead of the deprecated
    # `az functionapp deployment source config-zip`, which does not support Flex Consumption apps.
    az functionapp deploy `
        --resource-group $ResourceGroupName `
        --name $FunctionAppName `
        --src-path $zipPath `
        --type zip `
        -o none

    if ($LASTEXITCODE -ne 0) {
        throw "az functionapp deploy failed with exit code $LASTEXITCODE."
    }

    Write-Host "Function App '$FunctionAppName' deployed successfully." -ForegroundColor Green
}
finally {
    if (Test-Path $buildRoot) { Remove-Item -Path $buildRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($zipPath -and (Test-Path $zipPath)) { Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue }
}
