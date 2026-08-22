BeforeAll {
    Import-Module "$PSScriptRoot\..\src\functions\shared\EmergencyAccess.Remediation.psm1" -Force
    $groupId = '11111111-1111-1111-1111-111111111111'
    $policy1 = '22222222-2222-2222-2222-222222222222'
    $policy2 = '33333333-3333-3333-3333-333333333333'
}

Describe 'Invoke-EmergencyAccessRemediation' {
    BeforeEach {
        $script:policyState = @{}
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -MockWith {
            $uriText = $Uri.ToString()
            if ($Method -eq 'GET' -and $uriText.EndsWith('/policies')) {
                return @{ value = @($script:policyState.Values) }
            }
            $policyId = ($uriText -split '/')[-1]
            if ($Method -eq 'GET') {
                return $script:policyState[$policyId]
            }
            if ($Method -eq 'PATCH') {
                $payload = $Body | ConvertFrom-Json
                $script:policyState[$policyId].conditions.users.excludeGroups = @($payload.conditions.users.excludeGroups)
            }
        }
    }

    It 'rejects an invalid emergency group ID' {
        {
            Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId nope `
                -SkipManagedIdentityConnection
        } | Should -Throw '*valid Microsoft Entra object ID*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 0
    }

    It 'rejects an invalid targeted policy ID before calling Graph' {
        {
            Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
                -CAPolicyId nope -SkipManagedIdentityConnection
        } | Should -Throw '*valid Microsoft Entra object ID*'
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 0
    }

    It 'adds the group when exclusions are null and verifies the result' {
        $script:policyState[$policy1] = @{
            id = $policy1
            conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = $null } }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesUpdated | Should -Be 1
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 1 `
            -ParameterFilter { $Method -eq 'PATCH' -and $Body -match $groupId }
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 2 `
            -ParameterFilter { $Method -eq 'GET' -and $Uri.ToString().EndsWith($policy1) }
    }

    It 'does not patch a compliant policy' {
        $script:policyState[$policy1] = @{
            id = $policy1
            conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @($groupId) } }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesAlreadyExcluded | Should -Be 1
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 0 `
            -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'does not patch a non-user policy whose user target is None' {
        $script:policyState[$policy1] = @{
            id = $policy1
            conditions = @{ users = @{ includeUsers = @('None'); excludeGroups = @() } }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesUpdated | Should -Be 0
        $result.policiesAlreadyExcluded | Should -Be 1
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 0 `
            -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'preserves and deduplicates existing exclusions' {
        $existingId = '44444444-4444-4444-4444-444444444444'
        $script:policyState[$policy1] = @{
            id = $policy1
            conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @($existingId, $existingId) } }
        }

        Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        @($script:policyState[$policy1].conditions.users.excludeGroups) -join ',' |
            Should -Be "$existingId,$groupId"
    }

    It 'evaluates every policy in scheduled mode' {
        $script:policyState[$policy1] = @{
            id = $policy1
            conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @() } }
        }
        $script:policyState[$policy2] = @{
            id = $policy2
            conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @($groupId) } }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesEvaluated | Should -Be 2
        $result.policiesUpdated | Should -Be 1
        $result.policiesAlreadyExcluded | Should -Be 1
    }

    It 'follows every Graph page in scheduled mode' {
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET' -and $Uri.ToString().EndsWith('/policies')
        } -MockWith {
            @{
                value = @(@{
                    id = $policy1
                    conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @($groupId) } }
                })
                '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?next=2'
            }
        }
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET' -and $Uri -match 'next=2'
        } -MockWith {
            @{
                value = @(@{
                    id = $policy2
                    conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @($groupId) } }
                })
            }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesEvaluated | Should -Be 2
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 2 `
            -ParameterFilter { $Method -eq 'GET' }
    }

    It 'retrieves and verifies only the requested policy in targeted mode' {
        $script:policyState[$policy1] = @{
            id = $policy1
            conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @() } }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -CAPolicyId $policy1 -SkipManagedIdentityConnection

        $result.mode | Should -Be targeted
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 3 `
            -ParameterFilter { $Method -eq 'GET' -and $Uri.ToString().EndsWith($policy1) }
    }

    It 're-reads before patch and accepts a concurrent compliant update' {
        $script:getCount = 0
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET'
        } -MockWith {
            $script:getCount++
            if ($script:getCount -eq 1) {
                return @{ value = @(@{
                    id = $policy1
                    conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @() } }
                }) }
            }
            return @{
                id = $policy1
                conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @($groupId) } }
            }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesAlreadyExcluded | Should -Be 1
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 0 `
            -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'fails when post-write verification does not observe the exclusion' {
        $script:policyState[$policy1] = @{
            id = $policy1
            conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @() } }
        }
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'PATCH'
        }

        {
            Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
                -SkipManagedIdentityConnection
        } | Should -Throw '*Failed to remediate*'
    }

    It 'retries a throttled PATCH with bounded backoff' {
        $script:policyState[$policy1] = @{
            id = $policy1
            conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @() } }
        }
        $script:patchAttempts = 0
        Mock Start-Sleep -ModuleName EmergencyAccess.Remediation
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'PATCH'
        } -MockWith {
            $script:patchAttempts++
            if ($script:patchAttempts -eq 1) {
                throw 'HTTP 429 throttled'
            }
            $policyId = ($Uri.ToString() -split '/')[-1]
            $payload = $Body | ConvertFrom-Json
            $script:policyState[$policyId].conditions.users.excludeGroups = @($payload.conditions.users.excludeGroups)
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesUpdated | Should -Be 1
        $script:patchAttempts | Should -Be 2
        Should -Invoke Start-Sleep -ModuleName EmergencyAccess.Remediation -Times 1
    }

    It 'continues after a policy failure and returns structured failure data through the thrown exception' {
        $script:policyState[$policy1] = @{
            id = $policy1
            conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @() } }
        }
        $script:policyState[$policy2] = @{
            id = $policy2
            conditions = @{ users = @{ includeUsers = @('All'); excludeGroups = @() } }
        }
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'PATCH' -and $Uri.ToString().EndsWith($policy1)
        } -MockWith { throw 'Graph denied the update' }

        try {
            Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
                -SkipManagedIdentityConnection
            throw 'Expected remediation to fail.'
        }
        catch {
            $_.Exception.Data['Result'].policiesEvaluated | Should -Be 2
            $_.Exception.Data['Result'].policiesUpdated | Should -Be 1
            $_.Exception.Data['Result'].policiesFailed | Should -Be 1
            $_.Exception.Data['Result'].failed[0].error | Should -Match 'Graph denied'
            $_.Exception.Data['Result'].updatedPolicyIds | Should -Contain $policy2
        }
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 2 `
            -ParameterFilter { $Method -eq 'PATCH' }
    }
}
