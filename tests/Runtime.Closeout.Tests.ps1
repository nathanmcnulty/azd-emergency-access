Describe 'Runtime and teardown closeout guards' {
    BeforeAll {
        $automation = Get-Content "$PSScriptRoot\..\infra\modes\automation-scheduled.bicep" -Raw
        $logicApp = Get-Content "$PSScriptRoot\..\infra\modes\logicapp-scheduled.bicep" -Raw
        $preDown = Get-Content "$PSScriptRoot\..\scripts\Pre-Down.ps1" -Raw
        $tenantCleanup = Get-Content "$PSScriptRoot\..\scripts\Remove-TenantObjects.ps1" -Raw
    }

    It 'uses the proven shared Graph session for exact-owned application teardown' {
        $preDown | Should -Match 'Connect-EmergencyAccessGraph'
        $preDown | Should -Match "-Scopes @\('Application\.ReadWrite\.All'\)"
        $preDown | Should -Match 'Remove-GraphResource'
        $preDown | Should -Not -Match "-Resource 'https://graph\.microsoft\.com/'"
    }

    It 'fresh-reads, retries, skips non-user policies, and verifies Automation writes' {
        $automation | Should -Match 'function Invoke-GraphRequest'
        $automation | Should -Match 'for \(\$attempt = 1; \$attempt -le 4; \$attempt\+\+\)'
        $automation | Should -Match '\$freshPolicy = Invoke-GraphRequest -Method GET -Uri \$policyUri'
        $automation | Should -Match 'if \(''None'' -in \$includeUsers\)'
        $automation | Should -Match '\$verifiedPolicy = Invoke-GraphRequest -Method GET -Uri \$policyUri'
        $automation | Should -Match 'did not contain the emergency group after PATCH'

        $runbookMatch = [regex]::Match(
            $automation,
            "var runbookScript = '''\r?\n([\s\S]*?)\r?\n'''",
            [Text.RegularExpressions.RegexOptions]::Singleline
        )
        $runbookMatch.Success | Should -BeTrue
        $tokens = $null
        $errors = $null
        [Management.Automation.Language.Parser]::ParseInput(
            $runbookMatch.Groups[1].Value,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        @($errors) | Should -BeNullOrEmpty
    }

    It 'fresh-reads and verifies each Logic App write with bounded retries' {
        $logicApp | Should -Match 'Get_fresh_policy'
        $logicApp | Should -Match "body\(\\'Get_fresh_policy\\'\).*?includeUsers"
        $logicApp | Should -Match "excludeGroups: '@union\(coalesce\(body\(\\'Get_fresh_policy\\'\)"
        $logicApp | Should -Match 'Verify_policy'
        $logicApp | Should -Match 'Record_verification_failure'
        ([regex]::Matches($logicApp, 'count: 4')).Count | Should -BeGreaterOrEqual 4
    }

    It 'uses fresh verified cleanup writes and restores both CA and TAP state' {
        $tenantCleanup | Should -Match 'function Invoke-CleanupGraphRequest'
        $tenantCleanup | Should -Match '\$freshPolicy = Invoke-CleanupGraphRequest -Method GET -Uri \$policyUri'
        $tenantCleanup | Should -Match 'Record intent before PATCH so an ambiguous transport failure is also rolled back'
        $tenantCleanup | Should -Match 'still contains the emergency group after cleanup PATCH'
        $tenantCleanup | Should -Match 'function Restore-ConditionalAccessGroupReference'
        $tenantCleanup | Should -Match 'function Restore-TapGroupReference'
        $tenantCleanup | Should -Match 'Restore-TapGroupReference -Target \$tapTarget'
        $tenantCleanup | Should -Match 'graph\.microsoft\.com/v1\.0/policies/authenticationMethodsPolicy'
        $tenantCleanup | Should -Not -Match 'graph\.microsoft\.com/beta/policies/authenticationMethodsPolicy'
    }

    It 'keeps both edited PowerShell lifecycle scripts parseable' {
        foreach ($path in 'scripts\Pre-Down.ps1', 'scripts\Remove-TenantObjects.ps1') {
            $tokens = $null
            $errors = $null
            [Management.Automation.Language.Parser]::ParseFile(
                (Join-Path "$PSScriptRoot\.." $path),
                [ref]$tokens,
                [ref]$errors
            ) | Out-Null
            @($errors) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Tenant cleanup behavior' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $cleanupAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot '..\scripts\Remove-TenantObjects.ps1'),
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors) | Should -BeNullOrEmpty
        foreach ($name in @(
            'Invoke-CleanupGraphRequest',
            'Remove-ConditionalAccessGroupReferences',
            'Restore-ConditionalAccessGroupReference',
            'Remove-TapGroupReference',
            'Restore-TapGroupReference'
        )) {
            $definition = $cleanupAst.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $name
            }, $true)
            $definition | Should -Not -BeNullOrEmpty
            Set-Item -Path "Function:\global:$name" -Value $definition.Body.GetScriptBlock()
        }
    }

    AfterAll {
        foreach ($name in @(
            'Invoke-CleanupGraphRequest',
            'Remove-ConditionalAccessGroupReferences',
            'Restore-ConditionalAccessGroupReference',
            'Remove-TapGroupReference',
            'Restore-TapGroupReference'
        )) {
            Remove-Item -Path "Function:\global:$name" -ErrorAction SilentlyContinue
        }
    }

    It 'fresh-reads and verifies a Conditional Access removal while preserving other groups' {
        $emergencyGroupId = '11111111-1111-1111-1111-111111111111'
        $otherGroupId = '22222222-2222-2222-2222-222222222222'
        $policyId = '33333333-3333-3333-3333-333333333333'
        $script:excludeGroups = @($otherGroupId, $emergencyGroupId)
        Mock Invoke-CleanupGraphRequest {
            if ($Method -eq 'GET' -and $Uri.EndsWith('/policies')) {
                return @{ value = @(@{
                    id = $policyId
                    conditions = @{ users = @{ excludeGroups = @($script:excludeGroups) } }
                }) }
            }
            if ($Method -eq 'GET') {
                return @{ id = $policyId; conditions = @{ users = @{ excludeGroups = @($script:excludeGroups) } } }
            }
            $script:excludeGroups = @(($Body | ConvertFrom-Json).conditions.users.excludeGroups)
        }
        $changed = [Collections.Generic.List[string]]::new()

        Remove-ConditionalAccessGroupReferences -GroupId $emergencyGroupId -ChangedPolicyIds $changed

        @($script:excludeGroups) | Should -Be @($otherGroupId)
        @($changed) | Should -Be @($policyId)
        Should -Invoke Invoke-CleanupGraphRequest -Times 2 -ParameterFilter {
            $Method -eq 'GET' -and $Uri.EndsWith($policyId)
        }
    }

    It 'records and restores the exact TAP target after a partial cleanup failure' {
        $env:AZD_ENABLE_TAP_POLICY = 'false'
        $global:context = [pscustomobject]@{ Scopes = @('Policy.ReadWrite.AuthenticationMethod') }
        $groupId = '11111111-1111-1111-1111-111111111111'
        $otherGroupId = '22222222-2222-2222-2222-222222222222'
        $script:tapTargets = @(
            [pscustomobject]@{ targetType = 'group'; id = $groupId; isRegistrationRequired = $false },
            [pscustomobject]@{ targetType = 'group'; id = $otherGroupId; isRegistrationRequired = $false }
        )
        Mock Invoke-CleanupGraphRequest {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ state = 'enabled'; includeTargets = @($script:tapTargets) }
            }
            $script:tapTargets = @(($Body | ConvertFrom-Json).includeTargets)
        }
        $changedTargets = [Collections.Generic.List[object]]::new()

        Remove-TapGroupReference -GroupId $groupId -ChangedTargets $changedTargets
        $groupId | Should -Not -BeIn @($script:tapTargets.id)
        $changedTargets.Count | Should -Be 1

        Restore-TapGroupReference -Target $changedTargets[0]
        $groupId | Should -BeIn @($script:tapTargets.id)
        $otherGroupId | Should -BeIn @($script:tapTargets.id)
        Remove-Variable context -Scope Global -ErrorAction SilentlyContinue
    }

    It 'retries only transient cleanup responses with bounded backoff' {
        $script:attempts = 0
        Mock Start-Sleep
        Mock Invoke-MgGraphRequest {
            $script:attempts++
            if ($script:attempts -eq 1) {
                throw 'HTTP 429 throttled'
            }
            return @{ value = @() }
        }

        Invoke-CleanupGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/test' | Out-Null

        $script:attempts | Should -Be 2
        Should -Invoke Start-Sleep -Times 1
    }
}
