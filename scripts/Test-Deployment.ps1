[CmdletBinding()]
param(
    [Alias('PlanOnly')]
    [switch] $Plan,

    [switch] $TestDelivery,

    [string] $OutputPath = 'reports/deployment-validation.json',

    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Plan -and $TestDelivery) {
    throw '-Plan and -TestDelivery are mutually exclusive.'
}

$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$enginePath = Join-Path $PSScriptRoot 'vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1'
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    throw 'The deployment-validation component is missing. Synchronize it from azd-reference before validation.'
}

Import-Module $enginePath -Force
Import-Module (Join-Path $PSScriptRoot 'Deployment.Validation.psm1') -Force

$startedAt = [datetimeoffset]::UtcNow
$mode = if ($Plan) { 'plan' } elseif ($TestDelivery) { 'delivery' } else { 'verify' }
$definitions = @(Get-ProjectValidationDefinition)
$checks = @(Invoke-AzdValidationSet -Definitions $definitions -Plan:$Plan -AllowSyntheticDelivery:$TestDelivery)
$report = New-AzdValidationReport `
    -TemplateName 'azd-emergency-access' `
    -TemplateVersion '1.0.0' `
    -Mode $mode `
    -StartedAt $startedAt `
    -Checks $checks `
    -Environment @{
        name = [string] $env:AZURE_ENV_NAME
        tenantId = [string] $env:AZURE_TENANT_ID
        subscriptionId = [string] $env:AZURE_SUBSCRIPTION_ID
        resourceGroup = [string] $env:AZURE_RESOURCE_GROUP
    } `
    -Requirements @{
        tools = @('az', 'azd')
        modules = @()
        permissions = @('Azure resource read access', 'Logic App trigger and run read access for delivery testing')
    } `
    -NextSteps @(
        'Test every emergency account and recovery device and record the drill.',
        'Confirm every enabled email, Sentinel, Logic App, and Teams notification path with approved events.'
    )

$writtenPath = Write-AzdValidationReport -Report $report -OutputPath $OutputPath -RepositoryRoot $repositoryRoot
Write-AzdValidationSummary -Report $report
Write-Host "Validation report: $writtenPath"
if ($PassThru) { $report }
Assert-AzdValidationSucceeded -Report $report
