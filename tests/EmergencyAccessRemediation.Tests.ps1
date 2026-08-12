#Requires -Modules Pester, Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Pester tests for src/shared/EmergencyAccessRemediation.psm1, with Microsoft Graph calls fully
    mocked (no real Azure/Entra calls are made or required to run these tests).

.DESCRIPTION
    Run via scripts/test.ps1 or directly: Invoke-Pester -Path tests/EmergencyAccessRemediation.Tests.ps1

    Covers:
      - Preservation of existing conditions.users.excludeGroups entries.
      - Idempotency: a policy that already excludes the emergency access group is left unchanged
        and receives no PATCH call.
      - Single-policy (CAPolicyId) mode used by sentinel-function: only the identified policy is
        evaluated/patched.
      - Structured error handling: a failure patching one policy is captured in the result without
        aborting evaluation of the remaining policies.
      - Input validation: invalid GUIDs are rejected before any Graph call is made.
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\shared\EmergencyAccessRemediation.psm1'
    Import-Module $modulePath -Force
}

AfterAll {
    Remove-Module EmergencyAccessRemediation -ErrorAction SilentlyContinue
}

Describe 'Invoke-EmergencyAccessRemediation' {

    BeforeEach {
        $script:emergencyGroupId = '11111111-1111-1111-1111-111111111111'
    }

    Context 'All-policies mode (scheduled deployment modes)' {

        It 'preserves existing excludeGroups entries when appending the emergency access group' {
            $existingGroupId = '22222222-2222-2222-2222-222222222222'
            $policyId = '33333333-3333-3333-3333-333333333333'

            Mock -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest {
                if ($Method -eq 'GET') {
                    return [pscustomobject]@{
                        value = @(
                            [pscustomobject]@{
                                id         = $policyId
                                conditions = [pscustomobject]@{
                                    users = [pscustomobject]@{
                                        excludeGroups = @($existingGroupId)
                                    }
                                }
                            }
                        )
                    }
                }
            }

            $capturedBody = $null
            Mock -ModuleName EmergencyAccessRemediation Set-ConditionalAccessPolicyExclusion {
                $script:capturedBody = $ExcludeGroups
            }

            $result = Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $script:emergencyGroupId

            $result.mode | Should -Be 'all-policies'
            $result.policiesEvaluated | Should -Be 1
            $result.policiesUpdated | Should -Be 1
            $result.policiesFailed | Should -Be 0
            $script:capturedBody | Should -Contain $existingGroupId
            $script:capturedBody | Should -Contain $script:emergencyGroupId
            $script:capturedBody.Count | Should -Be 2

            Should -Invoke -ModuleName EmergencyAccessRemediation Set-ConditionalAccessPolicyExclusion -Times 1 -Exactly
        }

        It 'is idempotent: a policy that already excludes the group is left unchanged and is not patched' {
            $policyId = '44444444-4444-4444-4444-444444444444'

            Mock -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest {
                return [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id         = $policyId
                            conditions = [pscustomobject]@{
                                users = [pscustomobject]@{
                                    excludeGroups = @($script:emergencyGroupId)
                                }
                            }
                        }
                    )
                }
            }

            Mock -ModuleName EmergencyAccessRemediation Set-ConditionalAccessPolicyExclusion { }

            $result = Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $script:emergencyGroupId

            $result.policiesUpdated | Should -Be 0
            $result.policiesAlreadyExcluded | Should -Be 1
            $result.alreadyExcludedPolicyIds | Should -Contain $policyId

            Should -Invoke -ModuleName EmergencyAccessRemediation Set-ConditionalAccessPolicyExclusion -Times 0 -Exactly
        }

        It 'handles a policy with no existing conditions.users.excludeGroups property at all' {
            $policyId = '55555555-5555-5555-5555-555555555555'

            Mock -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest {
                return [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{
                            id         = $policyId
                            conditions = [pscustomobject]@{
                                users = [pscustomobject]@{}
                            }
                        }
                    )
                }
            }

            $capturedBody = $null
            Mock -ModuleName EmergencyAccessRemediation Set-ConditionalAccessPolicyExclusion {
                $script:capturedBody = $ExcludeGroups
            }

            $result = Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $script:emergencyGroupId

            $result.policiesUpdated | Should -Be 1
            $script:capturedBody | Should -Be @($script:emergencyGroupId)
        }

        It 'captures a failed PATCH for one policy without aborting evaluation of the others' {
            $okPolicyId = '66666666-6666-6666-6666-666666666666'
            $failPolicyId = '77777777-7777-7777-7777-777777777777'

            Mock -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest {
                return [pscustomobject]@{
                    value = @(
                        [pscustomobject]@{ id = $okPolicyId; conditions = [pscustomobject]@{ users = [pscustomobject]@{ excludeGroups = @() } } }
                        [pscustomobject]@{ id = $failPolicyId; conditions = [pscustomobject]@{ users = [pscustomobject]@{ excludeGroups = @() } } }
                    )
                }
            }

            Mock -ModuleName EmergencyAccessRemediation Set-ConditionalAccessPolicyExclusion {
                if ($PolicyId -eq $failPolicyId) {
                    throw 'Simulated Graph PATCH failure (e.g. 403 Forbidden).'
                }
            }

            $result = Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $script:emergencyGroupId

            $result.policiesEvaluated | Should -Be 2
            $result.policiesUpdated | Should -Be 1
            $result.policiesFailed | Should -Be 1
            $result.succeeded | Should -Be $false
            $result.failed[0].policyId | Should -Be $failPolicyId
            $result.updatedPolicyIds | Should -Contain $okPolicyId

            Should -Invoke -ModuleName EmergencyAccessRemediation Set-ConditionalAccessPolicyExclusion -Times 2 -Exactly
        }

        It 'follows @odata.nextLink pagination across multiple pages of policies' {
            $policyId1 = '88888888-8888-8888-8888-888888888888'
            $policyId2 = '99999999-9999-9999-9999-999999999999'

            Mock -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest {
                if ($Uri -match 'skiptoken') {
                    return [pscustomobject]@{
                        value = @(
                            [pscustomobject]@{ id = $policyId2; conditions = [pscustomobject]@{ users = [pscustomobject]@{ excludeGroups = @() } } }
                        )
                    }
                }
                return [pscustomobject]@{
                    value           = @(
                        [pscustomobject]@{ id = $policyId1; conditions = [pscustomobject]@{ users = [pscustomobject]@{ excludeGroups = @() } } }
                    )
                    '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$skiptoken=abc'
                }
            }

            Mock -ModuleName EmergencyAccessRemediation Set-ConditionalAccessPolicyExclusion { }

            $result = Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $script:emergencyGroupId

            $result.policiesEvaluated | Should -Be 2
            $result.policiesUpdated | Should -Be 2

            Should -Invoke -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest -Times 2 -Exactly
        }
    }

    Context 'Single-policy mode (sentinel-function, CAPolicyId supplied)' {

        It 'evaluates and remediates only the policy identified by CAPolicyId' {
            $targetPolicyId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

            Mock -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest {
                $Uri | Should -Match ([regex]::Escape($targetPolicyId))
                return [pscustomobject]@{
                    id         = $targetPolicyId
                    conditions = [pscustomobject]@{ users = [pscustomobject]@{ excludeGroups = @() } }
                }
            }

            Mock -ModuleName EmergencyAccessRemediation Set-ConditionalAccessPolicyExclusion { }

            $result = Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $script:emergencyGroupId -CAPolicyId $targetPolicyId

            $result.mode | Should -Be 'single-policy'
            $result.policiesEvaluated | Should -Be 1
            $result.policiesUpdated | Should -Be 1

            Should -Invoke -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest -Times 1 -Exactly
        }

        It 'does not call Graph GET for every policy when CAPolicyId is supplied (only the single policy endpoint)' {
            $targetPolicyId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            $calledUris = [System.Collections.Generic.List[string]]::new()

            Mock -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest {
                $calledUris.Add($Uri)
                return [pscustomobject]@{
                    id         = $targetPolicyId
                    conditions = [pscustomobject]@{ users = [pscustomobject]@{ excludeGroups = @($script:emergencyGroupId) } }
                }
            }

            $null = Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $script:emergencyGroupId -CAPolicyId $targetPolicyId

            $calledUris.Count | Should -Be 1
            $calledUris[0] | Should -Not -Match '\$skiptoken'
            $calledUris[0] | Should -Match "policies/$targetPolicyId$"
        }
    }

    Context 'Input validation' {

        It 'throws and makes no Graph call when EmergencyAccessGroupObjectId is not a valid GUID' {
            Mock -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest { }

            { Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId 'not-a-guid' } | Should -Throw

            Should -Invoke -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest -Times 0 -Exactly
        }

        It 'throws and makes no Graph call when CAPolicyId is not a valid GUID' {
            Mock -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest { }

            { Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $script:emergencyGroupId -CAPolicyId 'not-a-guid' } | Should -Throw

            Should -Invoke -ModuleName EmergencyAccessRemediation Invoke-MgGraphRequest -Times 0 -Exactly
        }
    }
}

Describe 'Test-EmergencyAccessGroupId' {
    It 'returns true for a well-formed GUID' {
        Test-EmergencyAccessGroupId -GroupObjectId '11111111-1111-1111-1111-111111111111' | Should -Be $true
    }

    It 'returns false for an empty string' {
        Test-EmergencyAccessGroupId -GroupObjectId '' | Should -Be $false
    }

    It 'returns false for a malformed GUID' {
        Test-EmergencyAccessGroupId -GroupObjectId 'not-a-guid' | Should -Be $false
    }
}
