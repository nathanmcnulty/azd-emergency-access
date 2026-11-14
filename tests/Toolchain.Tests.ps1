BeforeAll { $script:repositoryRoot = Split-Path $PSScriptRoot -Parent }

Describe 'Maintained PowerShell test toolchain' {
    It 'requires PowerShell 7.6 on every owned authoring entry point' {
        foreach ($entryPoint in Get-ChildItem (Join-Path $repositoryRoot 'scripts') -Filter '*.ps1' -File) {
            Get-Content $entryPoint.FullName -Raw | Should -Match '(?im)^#Requires -Version 7\.6\s*$'
        }
    }

    It 'pins hosted Pester validation to 6.2.0 and rejects empty or unsuccessful runs' {
        $workflow = Get-Content (Join-Path $repositoryRoot '.github/workflows/validate.yml') -Raw
        $workflow | Should -Match 'Install-Module Pester -RequiredVersion 6\.2\.0'
        $workflow | Should -Match '\$PSVersionTable\.PSVersion'
        $validatorPath = Join-Path $repositoryRoot 'scripts/Test-Repository.ps1'
        $validator = if (Test-Path $validatorPath) { Get-Content $validatorPath -Raw } else { $workflow }
        $validator | Should -Match "\.Result -ne 'Passed'"
        $validator | Should -Match '\.TotalCount -eq 0'
    }
}
