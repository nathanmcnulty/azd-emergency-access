Describe 'Early environment tenant validation' {
    BeforeAll {
        $script:validateEnvironmentPath = Join-Path $PSScriptRoot '..\scripts\Validate-Environment.ps1'
        $script:expectedSubscriptionId = '11111111-1111-4111-8111-111111111111'
        $script:otherSubscriptionId = '22222222-2222-4222-8222-222222222222'
        $script:actualTenantId = '33333333-3333-4333-8333-333333333333'
        $script:wrongTenantId = '44444444-4444-4444-8444-444444444444'

        function Invoke-ValidationFixture {
            param([AllowNull()][string] $TenantId)

            $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
            $azLog = Join-Path $fixtureRoot 'az.jsonl'
            $azdLog = Join-Path $fixtureRoot 'azd.jsonl'
            $azState = Join-Path $fixtureRoot 'selected-subscription.txt'

            @'
$commandArguments = @($args)
ConvertTo-Json -InputObject $commandArguments -Compress | Add-Content -LiteralPath $env:EA006_AZ_LOG
if ($commandArguments[0] -eq 'account' -and $commandArguments[1] -eq 'show') {
    $subscriptionId = if ($commandArguments -contains '--subscription') {
        $env:AZURE_SUBSCRIPTION_ID
    }
    elseif (Test-Path -LiteralPath $env:EA006_AZ_STATE) {
        Get-Content -LiteralPath $env:EA006_AZ_STATE -Raw
    }
    else {
        $env:EA006_INITIAL_ACTIVE_SUBSCRIPTION
    }
    [ordered]@{
        id = $subscriptionId.Trim()
        tenantId = $env:EA006_ACTUAL_TENANT
        environmentName = 'AzureCloud'
        user = [ordered]@{ type = 'user'; name = 'fixture@example.com' }
    } | ConvertTo-Json -Compress
    exit 0
}
if ($commandArguments[0] -eq 'account' -and $commandArguments[1] -eq 'set') {
    Set-Content -LiteralPath $env:EA006_AZ_STATE -Value $env:AZURE_SUBSCRIPTION_ID -NoNewline
    exit 0
}
if ($commandArguments[0] -eq 'login') { exit 0 }
Write-Error "Unexpected fake az call: $($commandArguments -join ' ')"
exit 91
'@ | Set-Content -LiteralPath (Join-Path $fixtureRoot 'az.ps1')

            @'
ConvertTo-Json -InputObject @($args) -Compress | Add-Content -LiteralPath $env:EA006_AZD_LOG
exit 0
'@ | Set-Content -LiteralPath (Join-Path $fixtureRoot 'azd.ps1')

            $environment = [ordered]@{
                PATH = $fixtureRoot
                PATHEXT = '.PS1;.EXE;.CMD;.BAT'
                SystemRoot = $env:SystemRoot
                TEMP = $env:TEMP
                TMP = $env:TMP
                CI = 'true'
                AZURE_SUBSCRIPTION_ID = $script:expectedSubscriptionId
                AZURE_LOCATION = 'westus2'
                AZURE_ENV_NAME = 'ea006-fixture'
                AZD_DEPLOYMENT_MODE = 'function-scheduled'
                AZD_SCHEDULE_CRON = '0 0 */6 * * *'
                AZD_SCHEDULE_INTERVAL = '6'
                AZD_SCHEDULE_FREQUENCY = 'Hour'
                AZD_AUTOMATION_TIME_ZONE = 'Etc/UTC'
                AZD_AUTOMATION_START_TIME = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
                AZD_MANAGE_EMERGENCY_IDENTITIES = 'false'
                AZD_USE_RESTRICTED_AU = 'false'
                AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT = 'false'
                AZD_ENABLE_TAP_POLICY = 'false'
                AZD_ENABLE_SIGNIN_ALERTS = 'false'
                AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS = 'false'
                AZD_SENTINEL_TEAMS_DELIVERY_MODE = 'admin-configured'
                AZD_EMERGENCY_GROUP_ID = '55555555-5555-4555-8555-555555555555'
                AZD_EMERGENCY_USER1_ID = '66666666-6666-4666-8666-666666666666'
                AZD_EMERGENCY_USER2_ID = '77777777-7777-4777-8777-777777777777'
                EA006_AZ_LOG = $azLog
                EA006_AZD_LOG = $azdLog
                EA006_AZ_STATE = $azState
                EA006_ACTUAL_TENANT = $script:actualTenantId
                EA006_INITIAL_ACTIVE_SUBSCRIPTION = $script:otherSubscriptionId
            }
            if ($TenantId) {
                $environment.AZURE_TENANT_ID = $TenantId
            }

            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.ArgumentList.Add('-NoLogo')
            $startInfo.ArgumentList.Add('-NoProfile')
            $startInfo.ArgumentList.Add('-File')
            $startInfo.ArgumentList.Add($script:validateEnvironmentPath)
            $startInfo.Environment.Clear()
            foreach ($entry in $environment.GetEnumerator()) {
                $startInfo.Environment[$entry.Key] = [string] $entry.Value
            }

            $process = [Diagnostics.Process]::Start($startInfo)
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()

            [pscustomobject]@{
                ExitCode = $process.ExitCode
                StandardOutput = $stdout
                StandardError = $stderr
                AzCalls = if (Test-Path -LiteralPath $azLog) {
                    @(Get-Content -LiteralPath $azLog | ForEach-Object { @($_ | ConvertFrom-Json) -join ' ' })
                }
                else { @() }
                AzdCalls = if (Test-Path -LiteralPath $azdLog) {
                    @(Get-Content -LiteralPath $azdLog | ForEach-Object { @($_ | ConvertFrom-Json) -join ' ' })
                }
                else { @() }
            }
        }
    }

    It 'rejects a supplied tenant mismatch before subscription selection or environment writes' {
        $result = Invoke-ValidationFixture -TenantId $script:wrongTenantId
        $azCommands = @($result.AzCalls)

        $result.ExitCode | Should -Not -Be 0
        $result.StandardError | Should -Match 'Tenant context mismatch'
        @($azCommands | Where-Object { $_ -like 'account set*' }).Count | Should -Be 0
        @($azCommands | Where-Object { $_ -like 'login*' }).Count | Should -Be 0
        $azCommands.Count | Should -Be 1
        $result.AzdCalls.Count | Should -Be 0
        $result.StandardOutput | Should -Not -Match 'Emergency access setup'
        $result.StandardOutput | Should -Not -Match 'Choose how Conditional Access exclusions will be maintained'
        $result.StandardOutput | Should -Not -Match 'Choose how emergency identities will be prepared'
    }

    It 'selects a matching requested subscription from another active cached subscription' {
        $result = Invoke-ValidationFixture -TenantId $script:actualTenantId
        $azCommands = @($result.AzCalls)

        $result.ExitCode | Should -Be 0
        $result.StandardOutput | Should -Match 'Environment contract validated'
        @($azCommands | Where-Object { $_ -like 'account set*' }).Count | Should -Be 1
        @($azCommands | Where-Object { $_ -like 'login*' }).Count | Should -Be 0
        $result.AzdCalls.Count | Should -Be 0
    }

    It 'resolves and persists a missing tenant from the requested subscription' {
        $result = Invoke-ValidationFixture -TenantId $null
        $azdCommands = @($result.AzdCalls)
        $azCommands = @($result.AzCalls)

        $result.ExitCode | Should -Be 0
        $result.StandardOutput | Should -Match 'Environment contract validated'
        $azdCommands | Should -Contain "env set AZURE_TENANT_ID $($script:actualTenantId)"
        @($azCommands | Where-Object { $_ -like 'account set*' }).Count | Should -Be 1
        @($azCommands | Where-Object { $_ -like 'login*' }).Count | Should -Be 0
    }
}
