BeforeAll {
    Import-Module "$PSScriptRoot\..\scripts\Function.Package.psm1" -Force
    $sourcePath = "$PSScriptRoot\..\src\functions"
}

Describe 'Mode-specific Function packaging' {
    It 'disables unsupported Flex managed dependencies' {
        $hostConfig = Get-Content -LiteralPath (Join-Path $sourcePath 'host.json') -Raw | ConvertFrom-Json
        $hostConfig.managedDependency.enabled | Should -BeFalse
        (Import-PowerShellDataFile (Join-Path $sourcePath 'requirements.psd1')).Count | Should -Be 0
    }

    It 'packages only the timer trigger for scheduled mode' {
        $destination = Join-Path $TestDrive 'scheduled'
        New-FunctionPackage -SourcePath $sourcePath -Mode function-scheduled `
            -DestinationPath $destination | Out-Null

        Test-Path (Join-Path $destination 'TimerRemediation\function.json') | Should -BeTrue
        Test-Path (Join-Path $destination 'HttpRemediation') | Should -BeFalse
        Test-Path (Join-Path $destination 'shared\EmergencyAccess.Remediation.psm1') | Should -BeTrue
    }

    It 'packages only the HTTP trigger for Sentinel mode' {
        $destination = Join-Path $TestDrive 'sentinel'
        New-FunctionPackage -SourcePath $sourcePath -Mode sentinel-function `
            -DestinationPath $destination | Out-Null

        Test-Path (Join-Path $destination 'HttpRemediation\function.json') | Should -BeTrue
        Test-Path (Join-Path $destination 'TimerRemediation') | Should -BeFalse
        Test-Path (Join-Path $destination 'shared\EmergencyAccess.Remediation.psm1') | Should -BeTrue
    }
}
