[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not $env:AZURE_RESOURCE_GROUP) {
    throw 'AZURE_RESOURCE_GROUP was not provided by the infrastructure deployment.'
}

$resources = & az resource list --resource-group $env:AZURE_RESOURCE_GROUP --query '[].{name:name,type:type}' -o json |
    ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect deployment resource group '$($env:AZURE_RESOURCE_GROUP)'."
}
if (@($resources).Count -eq 0) {
    throw "Deployment resource group '$($env:AZURE_RESOURCE_GROUP)' contains no resources."
}

Write-Host "Verified $(@($resources).Count) resource(s) for mode '$($env:AZD_DEPLOYMENT_MODE)' in '$($env:AZURE_RESOURCE_GROUP)'."

