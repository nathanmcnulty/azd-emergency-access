BeforeAll {
    $path = "$PSScriptRoot\..\scripts\Post-Provision.ps1"
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty
    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Write-PasskeySignInValidationResult'
    }, $true)
    $functionAst | Should -Not -BeNullOrEmpty
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

Describe 'Post-provision passkey sign-in validation handoff' {
    BeforeEach {
        $script:originalEnvironment = @{}
        foreach ($name in @(
            'AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS',
            'AZD_ENABLE_SIGNIN_ALERTS',
            'AZD_MANAGE_EMERGENCY_IDENTITIES',
            'AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT',
            'AZD_SECURITY_KEY_DRILL_FINGERPRINT',
            'AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID',
            'AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP',
            'AZD_SENTINEL_WORKSPACE_NAME',
            'AZD_SIGNIN_LOG_WORKSPACE_SUBSCRIPTION_ID',
            'AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP',
            'AZD_SIGNIN_LOG_WORKSPACE_NAME',
            'AZD_EMERGENCY_USER1_ID',
            'AZD_EMERGENCY_USER2_ID',
            'AZD_EMERGENCY_USER3_ID'
        )) {
            $script:originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        $global:LASTEXITCODE = 0
    }

    AfterEach {
        foreach ($entry in $script:originalEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
        Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    }

    It 'always reminds the administrator to test each key when alerting is disabled' {
        $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS = 'false'
        $env:AZD_ENABLE_SIGNIN_ALERTS = 'false'
        $env:AZD_MANAGE_EMERGENCY_IDENTITIES = 'true'

        $messages = @(& Write-PasskeySignInValidationResult 3>&1) | ForEach-Object { $_.ToString() }

        $messages -join "`n" | Should -Match 'every emergency-account security key'
        $messages -join "`n" | Should -Match 'Sign-in alerting is not enabled'
    }

    It 'hands externally managed drill and session revocation back to the owning process' {
        $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS = 'false'
        $env:AZD_ENABLE_SIGNIN_ALERTS = 'false'
        $env:AZD_MANAGE_EMERGENCY_IDENTITIES = 'false'

        $messages = @(& Write-PasskeySignInValidationResult 3>&1) | ForEach-Object { $_.ToString() }

        $messages -join "`n" | Should -Match 'External identity management is enabled'
        $messages -join "`n" | Should -Match 'organization-owned identity process'
        $messages -join "`n" | Should -Not -Match 'Run azd hooks run postprovision interactively'
    }

    It 'reports recent records without claiming that every key or alert was validated' {
        $env:AZD_MANAGE_EMERGENCY_IDENTITIES = 'true'
        $env:AZD_ENABLE_SIGNIN_ALERTS = 'true'
        $env:AZD_SIGNIN_LOG_WORKSPACE_SUBSCRIPTION_ID = '11111111-1111-1111-1111-111111111111'
        $env:AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP = 'rg-logs'
        $env:AZD_SIGNIN_LOG_WORKSPACE_NAME = 'law-signins'
        $env:AZD_EMERGENCY_USER1_ID = '22222222-2222-2222-2222-222222222222'
        $env:AZD_EMERGENCY_USER2_ID = '33333333-3333-3333-3333-333333333333'
        Mock az {
            $global:LASTEXITCODE = 0
            if ($args -contains 'show') {
                return '44444444-4444-4444-4444-444444444444'
            }
            return '[{"SignInCount":2,"Accounts":2}]'
        }

        $messages = @(& Write-PasskeySignInValidationResult 3>&1 6>&1) |
            ForEach-Object { $_.ToString() }

        $messages -join "`n" | Should -Match 'Observed 2 recent SigninLogs record'
        $messages -join "`n" | Should -Match 'does not replace testing every security key or confirming alert delivery'
        Should -Invoke az -Times 2
    }

    It 'warns instead of failing when SigninLogs cannot be queried yet' {
        $env:AZD_MANAGE_EMERGENCY_IDENTITIES = 'true'
        $env:AZD_ENABLE_SIGNIN_ALERTS = 'true'
        $env:AZD_SIGNIN_LOG_WORKSPACE_SUBSCRIPTION_ID = '11111111-1111-1111-1111-111111111111'
        $env:AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP = 'rg-logs'
        $env:AZD_SIGNIN_LOG_WORKSPACE_NAME = 'law-signins'
        $env:AZD_EMERGENCY_USER1_ID = '22222222-2222-2222-2222-222222222222'
        Mock az {
            if ($args -contains 'show') {
                $global:LASTEXITCODE = 0
                return '44444444-4444-4444-4444-444444444444'
            }
            $global:LASTEXITCODE = 1
        }

        $messages = @(& Write-PasskeySignInValidationResult 3>&1) |
            ForEach-Object { $_.ToString() }

        $messages -join "`n" | Should -Match 'opportunistic SigninLogs query could not be completed'
    }
}
