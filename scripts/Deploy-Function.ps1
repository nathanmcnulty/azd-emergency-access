[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if ($env:AZD_DEPLOYMENT_MODE -notin 'function-scheduled', 'sentinel-function') {
    Write-Host "Mode '$($env:AZD_DEPLOYMENT_MODE)' has no application package to deploy."
    return
}
if (-not $env:AZURE_FUNCTION_APP_NAME) {
    throw 'Infrastructure did not output AZURE_FUNCTION_APP_NAME.'
}
if (-not (Get-Command func -ErrorAction SilentlyContinue)) {
    throw 'Azure Functions Core Tools v4 is required to publish Function modes.'
}

Import-Module "$PSScriptRoot\Function.Package.psm1" -Force
$sourcePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\functions'))
$stagingPath = Join-Path ([IO.Path]::GetTempPath()) "azd-emergency-access-$([guid]::NewGuid())"
New-FunctionPackage -SourcePath $sourcePath -Mode $env:AZD_DEPLOYMENT_MODE `
    -DestinationPath $stagingPath | Out-Null

$modulesPath = Join-Path $stagingPath 'Modules'
Save-Module -Name Microsoft.Graph.Authentication -Path $modulesPath `
    -RequiredVersion '2.32.0' -Repository PSGallery -Force -ErrorAction Stop
if (-not (Test-Path -LiteralPath (Join-Path $modulesPath 'Microsoft.Graph.Authentication\2.32.0\Microsoft.Graph.Authentication.psd1'))) {
    throw 'Microsoft.Graph.Authentication was not included in the Function deployment package.'
}

Push-Location $stagingPath
try {
    & func azure functionapp publish $env:AZURE_FUNCTION_APP_NAME --powershell
    if ($LASTEXITCODE -ne 0) {
        throw "Function publication failed for $($env:AZURE_FUNCTION_APP_NAME)."
    }
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}
