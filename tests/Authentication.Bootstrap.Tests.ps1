BeforeAll {
    $bootstrapPath = Join-Path $PSScriptRoot '..\scripts\Bootstrap-Tenant.ps1'
    $tokens = $null
    $parseErrors = $null
    $script:bootstrapAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $bootstrapPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    $parseErrors | Should -BeNullOrEmpty

    function Import-BootstrapFunction {
        param([Parameter(Mandatory)][string] $Name)

        $definition = $script:bootstrapAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $Name
        }, $true)
        $definition | Should -Not -BeNullOrEmpty
        Set-Item -Path "Function:\global:$Name" -Value $definition.Body.GetScriptBlock()
    }

    foreach ($name in @(
        'Test-Interactive',
        'Invoke-Graph',
        'Set-AzdValue',
        'Clear-AzdValue',
        'Get-GraphCollection',
        'Assert-DistinctEmergencyUsers',
        'Confirm-EmergencyGroupAdoption',
        'Test-PasskeyRestrictionAllowsKey',
        'Assert-PasskeyPolicyApplicable',
        'Assert-EmergencySecurityKeys',
        'Invoke-TapOnboarding',
        'Invoke-EmergencySecurityKeyDrill'
    )) {
        Import-BootstrapFunction $name
    }
}

AfterAll {
    foreach ($name in @(
        'Test-Interactive',
        'Invoke-Graph',
        'Set-AzdValue',
        'Clear-AzdValue',
        'Get-GraphCollection',
        'Assert-DistinctEmergencyUsers',
        'Confirm-EmergencyGroupAdoption',
        'Test-PasskeyRestrictionAllowsKey',
        'Assert-PasskeyPolicyApplicable',
        'Assert-EmergencySecurityKeys',
        'Invoke-TapOnboarding',
        'Invoke-EmergencySecurityKeyDrill'
    )) {
        Remove-Item -Path "Function:\global:$Name" -ErrorAction SilentlyContinue
    }
}

Describe 'Emergency identity bootstrap behavior' {
    BeforeEach {
        $env:AZD_ADOPTED_EMERGENCY_GROUP_MEMBERSHIP_HASH = $null
        $env:AZD_ADOPTED_EMERGENCY_GROUP_ID = $null
        $env:AZD_ENABLE_TAP_POLICY = 'true'
        $script:graphRoot = 'https://graph.microsoft.com'
    }

    AfterEach {
        $env:AZD_ADOPTED_EMERGENCY_GROUP_MEMBERSHIP_HASH = $null
        $env:AZD_ADOPTED_EMERGENCY_GROUP_ID = $null
        $env:AZD_ENABLE_TAP_POLICY = $null
    }

    It 'rejects duplicate resolved emergency users' {
        $users = @(
            [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; userPrincipalName = 'one@contoso.onmicrosoft.com' },
            [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; userPrincipalName = 'two@contoso.onmicrosoft.com' }
        )

        { Assert-DistinctEmergencyUsers -Users $users } |
            Should -Throw '*must resolve to a distinct user*'
    }

    It 'retains additional group members only after exact interactive adoption' {
        $group = [pscustomobject]@{ id = '33333333-3333-3333-3333-333333333333'; displayName = 'Emergency Access Accounts' }
        $users = @(
            [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111' },
            [pscustomobject]@{ id = '22222222-2222-2222-2222-222222222222' }
        )
        Mock Get-GraphCollection {
            @(
                [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; userPrincipalName = 'one@contoso.onmicrosoft.com' },
                [pscustomobject]@{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'two@contoso.onmicrosoft.com' },
                [pscustomobject]@{ id = '44444444-4444-4444-4444-444444444444'; userPrincipalName = 'legacy@contoso.onmicrosoft.com' }
            )
        }
        Mock Test-Interactive { $true }
        Mock Read-Host { 'adopt' }
        Mock Set-AzdValue
        Mock Write-Warning
        $expectedState = '11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222,44444444-4444-4444-4444-444444444444'
        $expectedHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($expectedState))
        ).ToLowerInvariant()

        Confirm-EmergencyGroupAdoption -Group $group -Users $users

        Should -Invoke Set-AzdValue -ParameterFilter {
            $Name -eq 'AZD_EMERGENCY_GROUP_MEMBER_COUNT' -and $Value -eq '3'
        }
        Should -Invoke Set-AzdValue -ParameterFilter {
            $Name -eq 'AZD_ADOPTED_EMERGENCY_GROUP_ID' -and
                $Value -eq '33333333-3333-3333-3333-333333333333'
        }
        Should -Invoke Set-AzdValue -ParameterFilter {
            $Name -eq 'AZD_ADOPTED_EMERGENCY_GROUP_MEMBERSHIP_HASH' -and $Value -eq $expectedHash
        }
        Should -Invoke Write-Warning -ParameterFilter { $Message -match 'No members will be removed' }
    }

    It 'fingerprints the expected final membership before managed additions occur' {
        $group = [pscustomobject]@{ id = '33333333-3333-3333-3333-333333333333'; displayName = 'Emergency Access Accounts' }
        $users = @(
            [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; userPrincipalName = 'one@contoso.onmicrosoft.com' },
            [pscustomobject]@{ id = '22222222-2222-2222-2222-222222222222'; userPrincipalName = 'two@contoso.onmicrosoft.com' }
        )
        Mock Get-GraphCollection {
            @([pscustomobject]@{ id = '44444444-4444-4444-4444-444444444444'; userPrincipalName = 'legacy@contoso.onmicrosoft.com' })
        }
        Mock Test-Interactive { $true }
        Mock Read-Host { 'adopt' }
        Mock Set-AzdValue
        Mock Write-Warning
        $expectedState = '11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222,44444444-4444-4444-4444-444444444444'
        $expectedHash = [Convert]::ToHexString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($expectedState))
        ).ToLowerInvariant()

        Confirm-EmergencyGroupAdoption `
            -Group $group `
            -Users $users `
            -IncludeMissingSelectedMembers

        Should -Invoke Set-AzdValue -ParameterFilter {
            $Name -eq 'AZD_ADOPTED_EMERGENCY_GROUP_MEMBERSHIP_HASH' -and $Value -eq $expectedHash
        }
    }

    It 'fails external adoption when a selected account is not a group member' {
        $group = [pscustomobject]@{ id = '33333333-3333-3333-3333-333333333333'; displayName = 'Emergency Access Accounts' }
        $users = @(
            [pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111' },
            [pscustomobject]@{ id = '22222222-2222-2222-2222-222222222222' }
        )
        Mock Get-GraphCollection {
            @([pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111' })
        }
        Mock Set-AzdValue

        { Confirm-EmergencyGroupAdoption -Group $group -Users $users -RequireSelectedMembers } |
            Should -Throw '*does not contain selected emergency user*'
        Should -Invoke Set-AzdValue -Times 0
    }

    It 'clears stale adoption when only selected members remain' {
        $env:AZD_ADOPTED_EMERGENCY_GROUP_ID = '33333333-3333-3333-3333-333333333333'
        $env:AZD_ADOPTED_EMERGENCY_GROUP_MEMBERSHIP_HASH = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $group = [pscustomobject]@{ id = '33333333-3333-3333-3333-333333333333'; displayName = 'Emergency Access Accounts' }
        $users = @([pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111' })
        Mock Get-GraphCollection { @([pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111' }) }
        Mock Set-AzdValue
        Mock Clear-AzdValue

        Confirm-EmergencyGroupAdoption -Group $group -Users $users

        Should -Invoke Clear-AzdValue -ParameterFilter { $Name -eq 'AZD_ADOPTED_EMERGENCY_GROUP_MEMBERSHIP_HASH' }
        Should -Invoke Clear-AzdValue -ParameterFilter { $Name -eq 'AZD_ADOPTED_EMERGENCY_GROUP_ID' }
    }

    It 'requires direct passkey-policy applicability' {
        Mock Invoke-Graph {
            [pscustomobject]@{
                state = 'enabled'
                includeTargets = @([pscustomobject]@{ id = 'another-group' })
                excludeTargets = @()
            }
        }

        { Assert-PasskeyPolicyApplicable `
                -GroupId '33333333-3333-3333-3333-333333333333' `
                -Users @([pscustomobject]@{ id = 'user-1'; userPrincipalName = 'one@contoso.onmicrosoft.com' }) } |
            Should -Throw '*does not directly target*'
    }

    It 'rejects a user transitively targeted by a passkey-policy exclusion' {
        Mock Invoke-Graph {
            [pscustomobject]@{
                state = 'enabled'
                includeTargets = @([pscustomobject]@{ id = 'all_users' })
                excludeTargets = @([pscustomobject]@{ id = '44444444-4444-4444-4444-444444444444' })
            }
        }
        Mock Get-GraphCollection {
            @([pscustomobject]@{ id = '44444444-4444-4444-4444-444444444444' })
        }
        $users = @([pscustomobject]@{
            id = '11111111-1111-1111-1111-111111111111'
            userPrincipalName = 'one@contoso.onmicrosoft.com'
        })

        { Assert-PasskeyPolicyApplicable `
                -GroupId '33333333-3333-3333-3333-333333333333' `
                -Users $users } |
            Should -Throw '*excludes emergency account*through group*'
    }

    It 'counts only device-bound passkey methods after policy validation' {
        Mock Assert-PasskeyPolicyApplicable
        Mock Invoke-Graph {
            [pscustomobject]@{
                value = @(
                    [pscustomobject]@{ id = 'key-1'; passkeyType = 'deviceBound' },
                    [pscustomobject]@{ id = 'key-2'; passkeyType = 'synced' }
                )
            }
        }
        $users = @([pscustomobject]@{ id = '11111111-1111-1111-1111-111111111111'; userPrincipalName = 'one@contoso.onmicrosoft.com' })

        { Assert-EmergencySecurityKeys -Users $users -GroupId '33333333-3333-3333-3333-333333333333' } |
            Should -Throw '*has 1 device-bound FIDO2 security key*'
    }

    It 'rejects device-bound keys blocked by the applicable passkey profile' {
        Mock Assert-PasskeyPolicyApplicable {
            [pscustomobject]@{
                Policy = [pscustomobject]@{
                    passkeyProfiles = @([pscustomobject]@{
                        id = 'profile-1'
                        passkeyTypes = 'deviceBound'
                        keyRestrictions = [pscustomobject]@{
                            isEnforced = $true
                            enforcementType = 'allow'
                            aaGuids = @('allowed-aaguid')
                        }
                    })
                }
                Target = [pscustomobject]@{ allowedPasskeyProfiles = @('profile-1') }
            }
        }
        Mock Invoke-Graph {
            [pscustomobject]@{
                value = @(
                    [pscustomobject]@{ id = 'key-1'; passkeyType = 'deviceBound'; aaGuid = 'blocked-aaguid' },
                    [pscustomobject]@{ id = 'key-2'; passkeyType = 'deviceBound'; aaGuid = 'blocked-aaguid' }
                )
            }
        }
        $users = @([pscustomobject]@{ id = 'user-1'; userPrincipalName = 'one@contoso.onmicrosoft.com' })

        { Assert-EmergencySecurityKeys -Users $users -GroupId 'group-1' } |
            Should -Throw '*has 0 device-bound FIDO2 security key*allowed by its effective passkey profile*'
    }

    It 'changes the drill fingerprint when a registered physical key changes' {
        Mock Assert-PasskeyPolicyApplicable {
            [pscustomobject]@{ Policy = [pscustomobject]@{}; Target = [pscustomobject]@{} }
        }
        $script:secondKeyId = 'key-2'
        Mock Invoke-Graph {
            [pscustomobject]@{
                value = @(
                    [pscustomobject]@{ id = 'key-1'; passkeyType = 'deviceBound'; aaGuid = 'aaguid-1' },
                    [pscustomobject]@{ id = $script:secondKeyId; passkeyType = 'deviceBound'; aaGuid = 'aaguid-2' }
                )
            }
        }
        $users = @([pscustomobject]@{ id = 'user-1'; userPrincipalName = 'one@contoso.onmicrosoft.com' })

        $first = Assert-EmergencySecurityKeys -Users $users -GroupId 'group-1'
        $script:secondKeyId = 'replacement-key'
        $second = Assert-EmergencySecurityKeys -Users $users -GroupId 'group-1'

        $first | Should -Not -Be $second
    }

    It 'fails before creating TAPs when tenant policy requires one-time use' {
        Mock Assert-PasskeyPolicyApplicable
        Mock Test-Interactive { $true }
        Mock Invoke-Graph {
            if ($Method -eq 'GET' -and $Path -match 'TemporaryAccessPass$') {
                return [pscustomobject]@{
                    isUsableOnce = $true
                    minimumLifetimeInMinutes = 10
                    maximumLifetimeInMinutes = 480
                    includeTargets = @()
                }
            }
            throw "Unexpected Graph call: $Method $Path"
        }

        { Invoke-TapOnboarding -Users @([pscustomobject]@{ id = 'user-1' }) -GroupId 'group-1' } |
            Should -Throw '*permits only one-time passes*'
        Should -Invoke Invoke-Graph -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }

    It 'does not mutate TAP policy in a noninteractive terminal' {
        Mock Assert-PasskeyPolicyApplicable
        Mock Test-Interactive { $false }
        Mock Invoke-Graph { throw 'Graph should not be called' }

        { Invoke-TapOnboarding -Users @([pscustomobject]@{ id = 'user-1' }) -GroupId 'group-1' } |
            Should -Throw '*requires an interactive terminal*'
        Should -Invoke Invoke-Graph -Times 0
    }

    It 'requires the operator drill interactively' {
        Mock Test-Interactive { $true }
        Mock Read-Host { 'not-yet' }
        $users = @([pscustomobject]@{ userPrincipalName = 'one@contoso.onmicrosoft.com' })

        { Invoke-EmergencySecurityKeyDrill -Users $users } |
            Should -Throw '*sign-in drill was not confirmed*'
    }
}

Describe 'Authentication lifecycle wiring' {
    BeforeAll {
        $scriptText = Get-Content (Join-Path $PSScriptRoot '..\scripts\Bootstrap-Tenant.ps1') -Raw
        $validateText = Get-Content (Join-Path $PSScriptRoot '..\scripts\Validate-Environment.ps1') -Raw
    }

    It 'validates both identity modes immediately before unconditional reconciliation' {
        $workloadStart = $scriptText.LastIndexOf("if (`$Phase -in 'All', 'Workload')")
        $remediation = $scriptText.IndexOf('Invoke-EmergencyAccessRemediation', $workloadStart)
        $firstManagedGuard = $scriptText.IndexOf("if (`$env:AZD_MANAGE_EMERGENCY_IDENTITIES -eq 'true')", $workloadStart)
        $externalValidation = $scriptText.IndexOf('Resolve-ExternallyManagedEmergencyObjects', $firstManagedGuard)
        $roleMutationGuard = $scriptText.IndexOf(
            "if (`$env:AZD_MANAGE_EMERGENCY_IDENTITIES -eq 'true')",
            $firstManagedGuard + 1
        )

        $firstManagedGuard | Should -BeGreaterThan $workloadStart
        $externalValidation | Should -BeGreaterThan $firstManagedGuard
        $remediation | Should -BeGreaterThan $externalValidation
        $remediation | Should -BeLessThan $roleMutationGuard
    }

    It 'uses stable Graph endpoints for bootstrap TAP operations' {
        $scriptText | Should -Not -Match "TemporaryAccessPass' -Beta"
        $scriptText | Should -Not -Match 'temporaryAccessPassMethods[\s\S]{0,120}-Beta'
    }

    It 'requires both external user IDs for read-only validation' {
        $validateText | Should -Match 'Externally managed emergency identities require AZD_EMERGENCY_USER1_ID and AZD_EMERGENCY_USER2_ID'
        $validateText | Should -Match 'must identify two distinct emergency accounts'
    }

    It 'requires adoption before mutating a supplied managed group' {
        $identityStart = $scriptText.IndexOf("if (`$Phase -in 'All', 'Identities')")
        $preAdoption = $scriptText.IndexOf('-IncludeMissingSelectedMembers', $identityStart)
        $membershipWrite = $scriptText.IndexOf('Add-DirectoryObjectMember "groups/', $identityStart)
        $verification = $scriptText.IndexOf('-RequireSelectedMembers', $membershipWrite)

        $preAdoption | Should -BeGreaterThan $identityStart
        $membershipWrite | Should -BeGreaterThan $preAdoption
        $verification | Should -BeGreaterThan $membershipWrite
    }
}
