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
Import-Module "$PSScriptRoot\Function.Package.psm1" -Force
$sourcePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\functions'))
$tempPath = Join-Path ([IO.Path]::GetTempPath()) "azd-emergency-access-$([guid]::NewGuid())"
$stagingPath = Join-Path $tempPath 'content'
$packagePath = Join-Path $tempPath 'function.zip'
New-FunctionPackage -SourcePath $sourcePath -Mode $env:AZD_DEPLOYMENT_MODE `
    -DestinationPath $stagingPath | Out-Null

$modulesPath = Join-Path $stagingPath 'Modules'
Save-Module -Name Microsoft.Graph.Authentication -Path $modulesPath `
    -RequiredVersion '2.32.0' -Repository PSGallery -Force -ErrorAction Stop
if (-not (Test-Path -LiteralPath (Join-Path $modulesPath 'Microsoft.Graph.Authentication\2.32.0\Microsoft.Graph.Authentication.psd1'))) {
    throw 'Microsoft.Graph.Authentication was not included in the Function deployment package.'
}

try {
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingPath,
        $packagePath,
        [IO.Compression.CompressionLevel]::Optimal,
        $false
    )
    & az functionapp deployment source config-zip `
        --subscription $env:AZURE_SUBSCRIPTION_ID `
        --resource-group $env:AZURE_RESOURCE_GROUP `
        --name $env:AZURE_FUNCTION_APP_NAME `
        --src $packagePath `
        --timeout 600 `
        --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Function publication failed for $($env:AZURE_FUNCTION_APP_NAME)."
    }
}
finally {
    if (Test-Path -LiteralPath $tempPath) {
        Remove-Item -LiteralPath $tempPath -Recurse -Force
    }
}
