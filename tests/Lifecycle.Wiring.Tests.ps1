Describe 'Lifecycle security wiring' {
    BeforeAll {
        $bootstrap = Get-Content "$PSScriptRoot\..\scripts\Bootstrap-Tenant.ps1" -Raw
        $postProvision = Get-Content "$PSScriptRoot\..\scripts\Post-Provision.ps1" -Raw
        $preDown = Get-Content "$PSScriptRoot\..\scripts\Pre-Down.ps1" -Raw
        $preProvision = Get-Content "$PSScriptRoot\..\scripts\Pre-Provision.ps1" -Raw
        $validate = Get-Content "$PSScriptRoot\..\scripts\Validate-Environment.ps1" -Raw
        $testDeployment = Get-Content "$PSScriptRoot\..\scripts\Test-Deployment.ps1" -Raw
        $deploymentAdapter = Get-Content "$PSScriptRoot\..\scripts\Deployment.Validation.psm1" -Raw
        $deployFunction = Get-Content "$PSScriptRoot\..\scripts\Deploy-Function.ps1" -Raw
        $parameters = Get-Content "$PSScriptRoot\..\infra\main.parameters.json" -Raw
        $mainBicep = Get-Content "$PSScriptRoot\..\infra\main.bicep" -Raw
        $modeBicep = @(
            'automation-scheduled.bicep',
            'function-scheduled.bicep',
            'logicapp-scheduled.bicep',
            'sentinel-function.bicep'
        ) | ForEach-Object { Get-Content "$PSScriptRoot\..\infra\modes\$_" -Raw }
        $tenantGuards = Get-Content "$PSScriptRoot\..\scripts\Tenant.Guards.psm1" -Raw
        $logicApp = Get-Content "$PSScriptRoot\..\infra\modes\logicapp-scheduled.bicep" -Raw
        $sentinelBicep = Get-Content "$PSScriptRoot\..\infra\modes\sentinel-function.bicep" -Raw
        $remediation = Get-Content "$PSScriptRoot\..\src\functions\shared\EmergencyAccess.Remediation.psm1" -Raw
        $catalogWorkflow = Get-Content "$PSScriptRoot\..\.github\workflows\publish-azd-catalog.yml" -Raw
        $validationWorkflow = Get-Content "$PSScriptRoot\..\.github\workflows\validate.yml" -Raw
    }

    It 'reconciles a v2 API audience role and service principal' {
        $bootstrap | Should -Match 'requestedAccessTokenVersion\s*=\s*2'
        $bootstrap | Should -Match 'EmergencyAccess\.Remediate'
        $bootstrap | Should -Match 'identifierUris'
        $bootstrap | Should -Match 'servicePrincipals\?'
        $bootstrap | Should -Match "Invoke-Graph POST 'servicePrincipals'"
    }

    It 'records Sentinel ownership before fallible workload bootstrap' {
        $ownershipIndex = $preProvision.IndexOf("Replace('AZD_', 'AZD_OWNED_')")
        $bootstrapIndex = $preProvision.IndexOf("Bootstrap-Tenant.ps1`" -Phase Identities")
        $ownershipIndex | Should -BeGreaterOrEqual 0
        $bootstrapIndex | Should -BeGreaterThan $ownershipIndex
        $preProvision | Should -Match 'Unable to persist deterministic Sentinel resource ID'
        $postProvision | Should -Match 'refusing to overwrite it'
    }

    It 'allows preprovision to resolve tenant IDs before ARM parameter validation' {
        $parameters | Should -Match 'AZD_EMERGENCY_GROUP_ID='
        $parameters | Should -Match 'AZD_EMERGENCY_USER1_ID='
        $parameters | Should -Match 'AZD_EMERGENCY_USER2_ID='
        $parameters | Should -Match 'AZD_EMERGENCY_USER3_ID='
        $validate | Should -Match 'az group exists'
        $validate | Should -Match 'Set-AzdDefault AZURE_TENANT_ID \$subscriptionTenantId'
        $mainBicep | Should -Match "param emergencyAccessGroupObjectId string = ''"
        foreach ($mode in $modeBicep) {
            $mode | Should -Match '@minLength\(1\)\s*param emergencyAccessGroupObjectId string'
        }
    }

    It 'provides a resumable first-run administrator wizard' {
        $validate | Should -Match 'AZD_GUIDED_SETUP_ACTIVE'
        $validate | Should -Match "Scheduled Azure Function \(recommended for most organizations\)"
        $validate | Should -Match 'Choose how emergency identities will be prepared'
        $validate | Should -Match 'reusable 60-minute Temporary Access Pass \(TAP\)'
        $validate | Should -Match 'Choose emergency-account use notifications'
        $deployFunction | Should -Match 'ZipFile\]::CreateFromDirectory'
        $deployFunction | Should -Match 'az functionapp deployment source config-zip'
        $deployFunction | Should -Not -Match 'func azure functionapp publish'
        $validate | Should -Not -Match 'Functions Core Tools'
        $validate | Should -Match "Set-AzdValue AZD_GUIDED_SETUP_ACTIVE 'false'"
        $validate | Should -Match '\[default\]'
        $validate | Should -Match 'Continue with these choices\?'
        $validate | Should -Match 'Restart the setup wizard on the next azd up'
        $validate | Should -Match 'Protect the accounts and group with a restricted management administrative unit'
        $validate | Should -Match 'function Initialize-AzureCliContext'
        $validate | Should -Match "@\('login', '--output', 'none'\)"
        $validate | Should -Not -Match 'use-device-code'
    }

    It 'validates managed emergency identity safety properties' {
        $bootstrap | Should -Match 'function Assert-EmergencyUserSuitable'
        $bootstrap | Should -Match 'onPremisesSyncEnabled'
        $bootstrap | Should -Match 'must use the tenant''s onmicrosoft\.com domain'
        $bootstrap | Should -Match 'must be a static security group'
        $bootstrap | Should -Match 'is not a restricted management administrative unit'
        $validate | Should -Match 'AZD_EMERGENCY_DOMAIN must be the tenant initial domain'
    }

    It 'prints a concise deployment handoff' {
        $testDeployment | Should -Match "TemplateName 'azd-emergency-access'"
        $deploymentAdapter | Should -Match 'protected account\(s\)'
        $deploymentAdapter | Should -Match 'No emergency-account use notification path is enabled yet'
        $testDeployment | Should -Match 'Test every emergency account and recovery device'
    }

    It 'supports externally managed emergency identities without privileged identity mutations' {
        $validate | Should -Match "Set-AzdDefault AZD_MANAGE_EMERGENCY_IDENTITIES 'true'"
        $validate | Should -Match 'AZD_MANAGE_EMERGENCY_IDENTITIES=false requires AZD_EMERGENCY_GROUP_ID'
        $validate | Should -Match 'Externally managed emergency identities require AZD_EMERGENCY_USER1_ID and AZD_EMERGENCY_USER2_ID for read-only validation'
        $validate | Should -Match 'AZD_ENABLE_TAP_POLICY cannot be true when AZD_MANAGE_EMERGENCY_IDENTITIES=false'
        $identityPhase = $bootstrap.IndexOf("if (`$Phase -in 'All', 'Identities')")
        $identityGuard = $bootstrap.IndexOf("if (`$env:AZD_MANAGE_EMERGENCY_IDENTITIES -eq 'true')", $identityPhase)
        $workloadGuard = $bootstrap.LastIndexOf("if (`$env:AZD_MANAGE_EMERGENCY_IDENTITIES -eq 'true')")
        $resolveUser = $bootstrap.LastIndexOf('Resolve-EmergencyUser 1')
        $globalAdmin = $bootstrap.LastIndexOf("-RoleName 'Global Administrator'")
        $identityGuard | Should -BeGreaterOrEqual 0
        $resolveUser | Should -BeGreaterThan $identityGuard
        $workloadGuard | Should -BeGreaterThan $resolveUser
        $globalAdmin | Should -BeGreaterThan $workloadGuard
        $bootstrap | Should -Match "\}[\r\n ]+Resolve-SentinelServicePrincipal[\r\n ]+Ensure-FunctionAuthApplication"
        $tapGuard = $bootstrap.LastIndexOf("if (`$env:AZD_ENABLE_TAP_POLICY -eq 'true')")
        $tapInvocation = $bootstrap.LastIndexOf('Invoke-TapOnboarding -Users $users')
        $tapGuard | Should -BeGreaterThan $workloadGuard
        $tapInvocation | Should -BeGreaterThan $tapGuard
    }

    It 'hardens managed accounts before assigning permanent roles' {
        $ca = $bootstrap.LastIndexOf('Invoke-EmergencyAccessRemediation')
        $revoke = $bootstrap.LastIndexOf('Revoke-EmergencyUserSessions -Users')
        $roles = $bootstrap.LastIndexOf("-RoleName 'Global Administrator'")
        $ca | Should -BeGreaterOrEqual 0
        $revoke | Should -BeGreaterThan $ca
        $roles | Should -BeGreaterThan $revoke
        $bootstrap | Should -Match 'User\.RevokeSessions\.All'
        $bootstrap | Should -Match 'UserAuthenticationMethod\.Read\.All'
        $bootstrap | Should -Match 'authentication/fido2Methods'
        $bootstrap | Should -Match "passkeyType -eq 'deviceBound'"
        $bootstrap | Should -Match '\$allowedKeys\.Count -lt 2'
        $bootstrap | Should -Match 'AZD_SECURITY_KEY_DRILL_FINGERPRINT'
        $bootstrap | Should -Not -Match 'AZD_AUTHENTICATION_READY'
        $bootstrap | Should -Not -Match 'Confirm-AuthenticationReady'
        $bootstrap | Should -Match 'authentication/temporaryAccessPassMethods/\$\(\$createdTap\.MethodId\)'
        $bootstrap | Should -Match 'One or more onboarding TAPs could not be removed'
        $bootstrap | Should -Match 'AZD_ONBOARDED_EMERGENCY_USER_IDS'
        $remediation | Should -Match ([regex]::Escape("'None' -in `$includeUsers"))
    }

    It 'grants workload Graph roles only after immediate protection and authentication gates' {
        $workloadStart = $bootstrap.LastIndexOf("if (`$Phase -in 'All', 'Workload')")
        $remediation = $bootstrap.IndexOf('Invoke-EmergencyAccessRemediation', $workloadStart)
        $keyGate = $bootstrap.IndexOf('Assert-EmergencySecurityKeys', $remediation)
        $directoryRoles = $bootstrap.IndexOf("-RoleName 'Global Administrator'", $keyGate)
        $workloadRoles = $bootstrap.IndexOf('Ensure-GraphAppRoles $principalId.Trim()', $directoryRoles)

        $remediation | Should -BeGreaterThan $workloadStart
        $keyGate | Should -BeGreaterThan $remediation
        $directoryRoles | Should -BeGreaterThan $keyGate
        $workloadRoles | Should -BeGreaterThan $directoryRoles
    }

    It 'supports a supplemental lower-privilege emergency account' {
        $validate | Should -Match "Set-AzdDefault AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT 'false'"
        $bootstrap | Should -Match 'Resolve-EmergencyUser 3'
        $bootstrap | Should -Match 'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9'
        $bootstrap | Should -Match '0526716b-113d-4c15-b2c8-68e3c22b9f80'
        $bootstrap | Should -Match "-RoleName 'Authentication Policy Administrator'"
    }

    It 'cleans owned Sentinel rules even after a deployment mode change' {
        $preDown | Should -Match 'AZD_OWNED_SENTINEL_ALERT_RULE_ID -or'
        $preDown | Should -Not -Match "AZD_DEPLOYMENT_MODE -eq 'sentinel-function'"
        $preDown | Should -Match 'Test-OwnedSentinelResourceId'
        $preDown | Should -Match "ApiVersion = '2024-01-01-preview'"
    }

    It 'requires one matching tenant before Graph mutations' {
        $tenantGuards | Should -Match 'ExpectedTenantId -ne \$SubscriptionTenantId'
        $tenantGuards | Should -Match 'ExpectedTenantId -ne \$ActiveTenantId'
        $tenantGuards | Should -Match '\$active\.id -ne \[string\] \$env:AZURE_SUBSCRIPTION_ID'
        $bootstrap | Should -Match 'Assert-AzdTenantContext'
        $bootstrap | Should -Match 'Connect-MgGraph'
        $bootstrap | Should -Match '-TenantId \$env:AZURE_TENANT_ID'
        $bootstrap | Should -Match 'Get-MgContext'
        $bootstrap | Should -Match 'AZD_GRAPH_AUTH_INITIALIZED'
        $bootstrap | Should -Match 'Connect-MgGraph -NoWelcome'
        $bootstrap | Should -Match "\$Phase -ne 'Workload'"
        $bootstrap | Should -Match 'No additional authentication request was started'
        ([regex]::Matches($bootstrap, 'Connect-MgGraph[^\r\n]+-Scopes')).Count | Should -Be 1
        $bootstrap | Should -Match 'Policy\.ReadWrite\.ConditionalAccess'
        $bootstrap | Should -Not -Match 'az account get-access-token'
        $bootstrap | Should -Not -Match 'UseDeviceAuthentication'
    }

    It 'refuses incremental deployment mode transitions' {
        $validate | Should -Match 'AZD_PROVISIONED_MODE'
        $validate | Should -Match "Run 'azd down' before changing AZD_DEPLOYMENT_MODE"
        $postProvision | Should -Match 'azd env set AZD_PROVISIONED_MODE'
        $preDown | Should -Match "Clear-AzdEnvironmentValue 'AZD_PROVISIONED_MODE'"
    }

    It 'refuses replacement of exact-owned privileged objects' {
        $bootstrap | Should -Match 'function Assert-OwnedObjectNotReplaced'
        $bootstrap | Should -Match 'refusing to strand a privileged emergency object'
        $bootstrap | Should -Not -Match 'function Clear-MismatchedOwnership'
    }

    It 'merges the emergency group into the existing TAP targets' {
        $bootstrap | Should -Match "Invoke-Graph GET 'policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass'"
        $bootstrap | Should -Not -Match "authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass' -Beta"
        $bootstrap | Should -Match '\$includeTargets = @\(\$currentTap.includeTargets\)'
        $bootstrap | Should -Not -Match 'defaultLifetimeInMinutes = 120'
        $bootstrap | Should -Not -Match 'Enable Temporary Access Pass and create reusable 2-hour TAPs'
        $bootstrap | Should -Match 'lifetimeInMinutes = 60'
        $bootstrap | Should -Match 'isUsableOnce = \$false'
    }

    It 'fails the Logic App after processing when any policy patch fails' {
        $logicApp | Should -Match "name: 'PatchFailures'"
        $logicApp | Should -Match "type: 'AppendToArrayVariable'"
        $logicApp | Should -Match "type: 'Terminate'"
        $logicApp | Should -Match "runStatus: 'Failed'"
    }

    It 'enables the scheduled Logic App only after Graph roles are granted' {
        $logicApp = Get-Content "$PSScriptRoot\..\infra\modes\logicapp-scheduled.bicep" -Raw
        $postProvision = Get-Content "$PSScriptRoot\..\scripts\Post-Provision.ps1" -Raw
        $logicApp | Should -Match "state: 'Disabled'"
        $postProvision | Should -Match 'Bootstrap-Tenant.ps1" -Phase Workload[\s\S]+properties.state=Enabled'
    }

    It 'offers an opt-in live Sentinel notification delivery smoke test' {
        $testDeployment | Should -Match '\[switch\] \$TestDelivery'
        $testDeployment | Should -Match 'AllowSyntheticDelivery:\$TestDelivery'
        $validate | Should -Not -Match 'AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY'
        $deploymentAdapter | Should -Match 'Invoke-EmergencySentinelNotificationDelivery'
        $deploymentAdapter | Should -Match 'listCallbackUrl\?api-version=2019-05-01'
        $deploymentAdapter | Should -Match '\[TEST\] Emergency access notification delivery validation'
        $deploymentAdapter | Should -Match ([regex]::Escape("-Headers @{ 'x-ms-client-tracking-id' = `$trackingId }"))
        $deploymentAdapter | Should -Match 'properties\.correlation\.clientTrackingId -eq \$trackingId'
        $deploymentAdapter | Should -Match "status -ne 'Succeeded'"
        $deploymentAdapter | Should -Match 'Post_message_to_Teams_channel'
        $deploymentAdapter | Should -Match 'Post_adaptive_card_to_Teams'
        $deploymentAdapter | Should -Match 'Send_incident_email'
    }

    It 'verifies Sentinel Function Easy Auth and an unauthenticated 401 response' {
        $deploymentAdapter | Should -Match 'function Test-EmergencySentinelFunctionAuthentication'
        $deploymentAdapter | Should -Match 'authsettingsV2'
        $deploymentAdapter | Should -Match 'allowedPrincipals\.identities'
        $deploymentAdapter | Should -Match 'SkipHttpErrorCheck'
        $deploymentAdapter | Should -Match 'StatusCode -ne 401'
    }

    It 'uses the exact verified Sentinel service principal for Azure RBAC' {
        $postProvision | Should -Match '\$sentinelPrincipalId = \$env:AZD_SENTINEL_SERVICE_PRINCIPAL_ID'
        $postProvision | Should -Match "\$sentinelAppId = '98785600-1bb7-4fb9-b9fa-19afe2c8a360'"
        $postProvision | Should -Match 'az ad sp show'
        $postProvision | Should -Not -Match "--display-name 'Azure Security Insights'"
    }

    It 'pins validation dependencies and scopes the catalog token to one step' {
        $validationWorkflow | Should -Match 'Install-Module Pester -RequiredVersion 5\.7\.1'
        $validationWorkflow | Should -Not -Match 'Install-Module Pester -MinimumVersion'
        ([regex]::Matches($catalogWorkflow, 'GH_TOKEN:')).Count | Should -Be 1
        $catalogWorkflow | Should -Match 'GH_TOKEN: \$\{\{ secrets\.AZD_CATALOG_TOKEN \}\}'
        Test-Path "$PSScriptRoot\..\.github\dependabot.yml" | Should -BeTrue
    }

    It 'skips non-user Conditional Access policies' {
        $logicApp = Get-Content "$PSScriptRoot\..\infra\modes\logicapp-scheduled.bicep" -Raw
        $logicApp | Should -Match 'includeUsers'
        $logicApp | Should -Match "'None'"
    }

    It 'removes the exact-owned emergency group from Conditional Access before tenant deletion' {
        $cleanup = Get-Content "$PSScriptRoot\..\scripts\Remove-TenantObjects.ps1" -Raw
        $cleanup | Should -Match 'function Remove-ConditionalAccessGroupReferences'
        $cleanup | Should -Match 'excludeGroups = \$remainingGroups'
        $cleanup | Should -Match 'EmergencyAccess\.Remediation\.psm1'
        $cleanup | Should -Match 'Remove-ConditionalAccessGroupReferences[\s\S]+-ChangedPolicyIds \$changedConditionalAccessPolicies[\s\S]+Invoke-MgGraphRequest -Method DELETE'
        $cleanup | Should -Match '\[Collections\.Generic\.List\[string\]\] \$ChangedPolicyIds'
        $cleanup.IndexOf('try {', $cleanup.LastIndexOf('$changedConditionalAccessPolicies =')) | Should -BeLessThan $cleanup.LastIndexOf('Remove-ConditionalAccessGroupReferences')
        $cleanup | Should -Match 'Invoke-EmergencyAccessRemediation[\s\S]+-CAPolicyId \$policyId'
        $cleanup | Should -Match 'all removed Conditional Access exclusions were restored'
        $cleanup | Should -Match '\$attempt -le 4 -and \$groupState -eq ''unknown'''
        $cleanup | Should -Match 'rollback was attempted for every recorded policy change'
        $cleanup | Should -Match 'Connect-MgGraph'
        $cleanup | Should -Match 'AZD_OWNED_EMERGENCY_USER3_ID'
        $cleanup | Should -Match 'AZD_ADOPTED_EMERGENCY_GROUP_MEMBERSHIP_HASH'
        $cleanup | Should -Match 'AZD_EMERGENCY_GROUP_MEMBER_COUNT'
        $cleanup | Should -Match 'AZD_SECURITY_KEY_DRILL_FINGERPRINT'
        $cleanup | Should -Match 'function Remove-TapGroupReference'
        $cleanup | Should -Match 'Policy\.ReadWrite\.AuthenticationMethod'
        $cleanup | Should -Match 'Connect-MgGraph -NoWelcome'
        $cleanup | Should -Not -Match 'Connect-MgGraph[\s\S]{0,150}-Scopes'
        $cleanup | Should -Not -Match 'az account get-access-token'
        $cleanup | Should -Not -Match 'UseDeviceAuthentication'
    }

    It 'fails closed when Sentinel Function authentication is absent' {
        $sentinelBicep | Should -Match '@minLength\(1\)\s*param functionAuthClientId string'
        $sentinelBicep | Should -Match '@minLength\(1\)\s*param functionAuthAudience string'
    }
}

Describe 'Tenant guards' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\scripts\Tenant.Guards.psm1" -Force
    }

    It 'permits one exact tenant across environment subscription and active context' {
        { Assert-TenantMatch -ExpectedTenantId '11111111-1111-1111-1111-111111111111' -SubscriptionTenantId '11111111-1111-1111-1111-111111111111' -ActiveTenantId '11111111-1111-1111-1111-111111111111' } | Should -Not -Throw
    }

    It 'rejects an active tenant mismatch before mutations' {
        { Assert-TenantMatch -ExpectedTenantId '11111111-1111-1111-1111-111111111111' -SubscriptionTenantId '11111111-1111-1111-1111-111111111111' -ActiveTenantId '22222222-2222-2222-2222-222222222222' } | Should -Throw '*Tenant context mismatch*'
    }

    It 'rejects an active subscription mismatch in the same tenant' {
        InModuleScope Tenant.Guards {
            $oldSubscription = $env:AZURE_SUBSCRIPTION_ID
            $oldTenant = $env:AZURE_TENANT_ID
            try {
                $env:AZURE_SUBSCRIPTION_ID = '11111111-1111-4111-8111-111111111111'
                $env:AZURE_TENANT_ID = '33333333-3333-4333-8333-333333333333'
                $script:tenantGuardAzCallCount = 0
                Mock az {
                    $global:LASTEXITCODE = 0
                    $script:tenantGuardAzCallCount++
                    if ($script:tenantGuardAzCallCount -eq 1) {
                        return '{"id":"11111111-1111-4111-8111-111111111111","tenantId":"33333333-3333-4333-8333-333333333333"}'
                    }
                    return '{"id":"22222222-2222-4222-8222-222222222222","tenantId":"33333333-3333-4333-8333-333333333333"}'
                }
                { Assert-AzdTenantContext } | Should -Throw '*Azure subscription mismatch*'
            }
            finally {
                $env:AZURE_SUBSCRIPTION_ID = $oldSubscription
                $env:AZURE_TENANT_ID = $oldTenant
            }
        }
    }

    It 'hydrates a missing process value from the selected azd environment' {
        InModuleScope Tenant.Guards {
            $oldValue = $env:AZD_VALIDATION_HYDRATION_TEST
            try {
                $env:AZD_VALIDATION_HYDRATION_TEST = $null
                Mock Invoke-AzdEnvironmentValueRead { 'hydrated-value' }
                Get-AzdEnvironmentValue 'AZD_VALIDATION_HYDRATION_TEST' | Should -Be 'hydrated-value'
                $env:AZD_VALIDATION_HYDRATION_TEST | Should -Be 'hydrated-value'
            }
            finally {
                $env:AZD_VALIDATION_HYDRATION_TEST = $oldValue
            }
            Assert-MockCalled Invoke-AzdEnvironmentValueRead -Times 1 -Exactly
        }
    }
}
