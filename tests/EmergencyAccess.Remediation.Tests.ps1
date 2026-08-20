BeforeAll {
    Import-Module "$PSScriptRoot\..\src\functions\shared\EmergencyAccess.Remediation.psm1" -Force
    $groupId = '11111111-1111-1111-1111-111111111111'
    $policy1 = '22222222-2222-2222-2222-222222222222'
    $policy2 = '33333333-3333-3333-3333-333333333333'
}

Describe 'Invoke-EmergencyAccessRemediation' {
    BeforeEach {
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation
    }

    It 'rejects an invalid emergency group ID' {
        {
            Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId nope `
                -SkipManagedIdentityConnection
        } | Should -Throw '*valid Microsoft Entra object ID*'
    }

    It 'adds the group when exclusions are null' {
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET'
        } -MockWith {
            @{ value = @(@{ id = $policy1; conditions = @{ users = @{ excludeGroups = $null } } }) }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesUpdated | Should -Be 1
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 1 `
            -ParameterFilter { $Method -eq 'PATCH' -and $Body -match $groupId }
    }

    It 'does not patch a compliant policy' {
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET'
        } -MockWith {
            @{ value = @(@{
                id = $policy1
                conditions = @{ users = @{ excludeGroups = @($groupId) } }
            }) }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesAlreadyExcluded | Should -Be 1
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 0 `
            -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'does not patch a non-user policy whose user target is None' {
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET'
        } -MockWith {
            @{ value = @(@{ id = $policy1; conditions = @{ users = @{ includeUsers = @('None'); excludeGroups = @() } } }) }
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
        $script:patchedBody = $null
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET'
        } -MockWith {
            @{ value = @(@{
                id = $policy1
                conditions = @{ users = @{ excludeGroups = @($existingId, $existingId) } }
            }) }
        }
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'PATCH'
        } -MockWith {
            $script:patchedBody = $Body
        }

        Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $exclusions = ($script:patchedBody | ConvertFrom-Json).conditions.users.excludeGroups
        $exclusions -join ',' | Should -Be "$existingId,$groupId"
    }

    It 'evaluates every policy in scheduled mode' {
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET'
        } -MockWith {
            @{ value = @(
                @{ id = $policy1; conditions = @{ users = @{ excludeGroups = @() } } },
                @{ id = $policy2; conditions = @{ users = @{ excludeGroups = @($groupId) } } }
            ) }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesEvaluated | Should -Be 2
        $result.policiesUpdated | Should -Be 1
        $result.policiesAlreadyExcluded | Should -Be 1
    }

    It 'follows every Graph page in scheduled mode' {
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET' -and $Uri -notmatch 'next=2'
        } -MockWith {
            @{
                value = @(@{
                    id = $policy1
                    conditions = @{ users = @{ excludeGroups = @($groupId) } }
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
                    conditions = @{ users = @{ excludeGroups = @($groupId) } }
                })
            }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -SkipManagedIdentityConnection

        $result.policiesEvaluated | Should -Be 2
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 2 `
            -ParameterFilter { $Method -eq 'GET' }
    }

    It 'retrieves only the requested policy in targeted mode' {
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET'
        } -MockWith {
            @{ id = $policy1; conditions = @{ users = @{ excludeGroups = @() } } }
        }

        $result = Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
            -CAPolicyId $policy1 -SkipManagedIdentityConnection

        $result.mode | Should -Be targeted
        Should -Invoke Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -Times 1 `
            -ParameterFilter { $Method -eq 'GET' -and $Uri.ToString().EndsWith($policy1) }
    }

    It 'returns structured failure data through the thrown exception' {
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'GET'
        } -MockWith {
            @{ value = @(@{ id = $policy1; conditions = @{ users = @{ excludeGroups = @() } } }) }
        }
        Mock Invoke-MgGraphRequest -ModuleName EmergencyAccess.Remediation -ParameterFilter {
            $Method -eq 'PATCH'
        } -MockWith { throw 'Graph denied the update' }

        try {
            Invoke-EmergencyAccessRemediation -EmergencyAccountsGroupObjectId $groupId `
                -SkipManagedIdentityConnection
            throw 'Expected remediation to fail.'
        }
        catch {
            $_.Exception.Data['Result'].policiesFailed | Should -Be 1
            $_.Exception.Data['Result'].failed[0].error | Should -Match 'Graph denied'
        }
    }
}
