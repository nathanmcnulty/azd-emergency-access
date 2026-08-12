#Requires -Version 7.0
<#
.SYNOPSIS
    Test entry point for the azd-emergency-access template.

.DESCRIPTION
    Runs everything that can be validated locally without deploying any Azure resources or
    connecting to a real tenant:
      1. PowerShell syntax (AST parse) for every .ps1/.psm1 file in src/ and scripts/.
      2. Pester unit tests under tests/ (Microsoft Graph is fully mocked).
      3. `az bicep build` against infra/main.bicep, if the Azure CLI/Bicep tooling is available.

    Intended to be run by contributors and CI before opening a pull request. Exits non-zero if any
    stage fails.
#>

[CmdletBinding()]
param(
    [switch] $SkipBicep
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
$overallSuccess = $true

Write-Host '=== azd-emergency-access: test.ps1 ===' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. PowerShell syntax validation
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- PowerShell syntax (AST parse) ---' -ForegroundColor Cyan

$psFiles = Get-ChildItem -Path $repoRoot -Recurse -Include '*.ps1', '*.psm1' |
    Where-Object { $_.FullName -notmatch '\\node_modules\\' }

foreach ($file in $psFiles) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null

    if ($parseErrors.Count -gt 0) {
        $overallSuccess = $false
        Write-Host "FAIL: $($file.FullName)" -ForegroundColor Red
        foreach ($parseError in $parseErrors) {
            Write-Host "  $($parseError.Message)" -ForegroundColor Red
        }
    }
    else {
        Write-Host "OK: $($file.FullName.Substring($repoRoot.Length + 1))"
    }
}

# ---------------------------------------------------------------------------
# 2. Pester unit tests
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '--- Pester unit tests ---' -ForegroundColor Cyan

if (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge '5.0.0' }) {
    Import-Module Pester -MinimumVersion 5.0 -Force

    $pesterConfig = New-PesterConfiguration
    $pesterConfig.Run.Path = Join-Path $repoRoot 'tests'
    $pesterConfig.Run.PassThru = $true
    $pesterConfig.Output.Verbosity = 'Normal'

    $pesterResult = Invoke-Pester -Configuration $pesterConfig

    if ($pesterResult.FailedCount -gt 0) {
        $overallSuccess = $false
        Write-Host "Pester: $($pesterResult.FailedCount) test(s) failed." -ForegroundColor Red
    }
    else {
        Write-Host "Pester: all $($pesterResult.PassedCount) test(s) passed." -ForegroundColor Green
    }
}
else {
    Write-Warning 'Pester 5.x is not installed; skipping unit tests. Install with: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force'
}

# ---------------------------------------------------------------------------
# 3. Bicep build
# ---------------------------------------------------------------------------
if (-not $SkipBicep) {
    Write-Host ''
    Write-Host '--- az bicep build ---' -ForegroundColor Cyan

    if (Get-Command -Name 'az' -ErrorAction SilentlyContinue) {
        $bicepFile = Join-Path $repoRoot 'infra\main.bicep'
        $bicepOutFile = Join-Path $repoRoot 'infra\main.test-build.json'

        az bicep build --file $bicepFile --outfile $bicepOutFile 2>&1 | ForEach-Object { Write-Host $_ }
        $bicepExitCode = $LASTEXITCODE

        if (Test-Path $bicepOutFile) {
            Remove-Item $bicepOutFile -ErrorAction SilentlyContinue
        }

        # ---------------------------------------------------------------------------
        # 4. Function trigger isolation metadata
        # ---------------------------------------------------------------------------
        Write-Host ''
        Write-Host '--- Function trigger isolation metadata ---' -ForegroundColor Cyan
        $timerBinding = Get-Content (Join-Path $repoRoot 'src\function\RemediateCAPolicies\function.json') -Raw | ConvertFrom-Json
        $httpBinding = Get-Content (Join-Path $repoRoot 'src\function\HttpRemediateCAPolicy\function.json') -Raw | ConvertFrom-Json
        if (($timerBinding.bindings.type -notcontains 'timerTrigger') -or ($httpBinding.bindings.type -notcontains 'httpTrigger')) {
            $overallSuccess = $false
            Write-Host 'Function trigger metadata is invalid.' -ForegroundColor Red
        }
        elseif ((Get-Content (Join-Path $repoRoot 'scripts\Publish-FunctionApp.ps1') -Raw) -notmatch 'excludedTrigger') {
            $overallSuccess = $false
            Write-Host 'Function packaging does not isolate triggers by deployment mode.' -ForegroundColor Red
        }
        else {
            Write-Host 'Timer and HTTP metadata are valid and packaging isolates them by deployment mode.' -ForegroundColor Green
        }

        if ($bicepExitCode -ne 0) {
            $overallSuccess = $false
            Write-Host "az bicep build failed with exit code $bicepExitCode." -ForegroundColor Red
        }
        else {
            Write-Host 'az bicep build succeeded.' -ForegroundColor Green
        }
    }
    else {
        Write-Warning 'Azure CLI (az) not found on PATH; skipping bicep build validation.'
    }
}

Write-Host ''
if ($overallSuccess) {
    Write-Host 'All checks passed.' -ForegroundColor Green
    exit 0
}
else {
    Write-Host 'One or more checks failed. See output above.' -ForegroundColor Red
    exit 1
}
