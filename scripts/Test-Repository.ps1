[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Assert-LastExitCode {
    param([Parameter(Mandatory)][string] $Operation)

    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed with exit code $LASTEXITCODE."
    }
}

function Remove-GeneratorMetadata {
    param([AllowNull()] $Value)

    if ($null -eq $Value -or $Value -is [string] -or $Value.GetType().IsValueType) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) {
            if ([string] $key -ne '_generator') {
                $result[[string] $key] = Remove-GeneratorMetadata -Value $Value[$key]
            }
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [pscustomobject]) {
        return @($Value | ForEach-Object { Remove-GeneratorMetadata -Value $_ })
    }

    $result = [ordered]@{}
    foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
        if ($property.Name -ne '_generator') {
            $result[$property.Name] = Remove-GeneratorMetadata -Value $property.Value
        }
    }
    return $result
}

$parseErrors = [System.Collections.Generic.List[object]]::new()
Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File |
    Where-Object Extension -in '.ps1', '.psm1' |
    ForEach-Object {
        $tokens = $null
        $fileErrors = $null
        [void] [System.Management.Automation.Language.Parser]::ParseFile(
            $_.FullName,
            [ref] $tokens,
            [ref] $fileErrors
        )
        foreach ($fileError in @($fileErrors)) {
            $parseErrors.Add($fileError)
        }
    }
if ($parseErrors.Count -gt 0) {
    throw ($parseErrors | Format-List | Out-String)
}

Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'src/functions') -Recurse -Filter '*.json' -File |
    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json | Out-Null }

$pester = Get-Module -ListAvailable Pester |
    Where-Object Version -ge ([version] '5.7.1') |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester) {
    throw 'Pester 5.7.1 or later is required for offline repository validation.'
}
$graphAuthentication = Get-Module -ListAvailable Microsoft.Graph.Authentication |
    Where-Object Version -ge ([version] '2.30.0') |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $graphAuthentication) {
    throw 'Microsoft.Graph.Authentication 2.30.0 or later is required for offline repository tests.'
}

Import-Module $pester.Path -Force
Set-StrictMode -Off
try {
    $testResult = Invoke-Pester -Path (Join-Path $repositoryRoot 'tests') -Output Detailed -PassThru
}
finally {
    Set-StrictMode -Version Latest
}
if ($testResult.FailedCount -gt 0) {
    throw "$($testResult.FailedCount) repository test(s) failed."
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI with an already-installed Bicep CLI is required for offline repository validation.'
}
& az bicep version | Out-Null
Assert-LastExitCode -Operation 'Bicep availability check'

$bicepPath = Join-Path $repositoryRoot 'infra/main.bicep'
$armPath = Join-Path $repositoryRoot 'infra/main.json'
$compiledOutput = @(& az bicep build --file $bicepPath --no-restore --stdout)
Assert-LastExitCode -Operation 'Bicep build'
$compiledTemplate = ($compiledOutput -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
$checkedInTemplate = Get-Content -LiteralPath $armPath -Raw | ConvertFrom-Json -Depth 100
$compiledComparable = Remove-GeneratorMetadata -Value $compiledTemplate | ConvertTo-Json -Depth 100 -Compress
$checkedInComparable = Remove-GeneratorMetadata -Value $checkedInTemplate | ConvertTo-Json -Depth 100 -Compress
if ($compiledComparable -cne $checkedInComparable) {
    throw 'Compiled Bicep structure differs from the checked-in ARM template.'
}

& git -C $repositoryRoot diff --check
Assert-LastExitCode -Operation 'Git diff whitespace check'

Write-Host "Offline repository validation passed: $($testResult.PassedCount) Pester tests."
