Describe 'Lifecycle security wiring' {
    BeforeAll {
        $bootstrap = Get-Content "$PSScriptRoot\..\scripts\Bootstrap-Tenant.ps1" -Raw
        $postProvision = Get-Content "$PSScriptRoot\..\scripts\Post-Provision.ps1" -Raw
        $preDown = Get-Content "$PSScriptRoot\..\scripts\Pre-Down.ps1" -Raw
        $preProvision = Get-Content "$PSScriptRoot\..\scripts\Pre-Provision.ps1" -Raw
        $validate = Get-Content "$PSScriptRoot\..\scripts\Validate-Environment.ps1" -Raw
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
        $validate | Should -Match 'az group exists'
        $validate | Should -Match 'Set-AzdDefault AZURE_TENANT_ID \$subscriptionTenantId'
        $mainBicep | Should -Match "param emergencyAccessGroupObjectId string = ''"
        foreach ($mode in $modeBicep) {
            $mode | Should -Match '@minLength\(1\)\s*param emergencyAccessGroupObjectId string'
        }
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
        $bootstrap | Should -Match 'Assert-AzdTenantContext'
        $bootstrap | Should -Match '--subscription \$env:AZURE_SUBSCRIPTION_ID'
        $bootstrap | Should -Not -Match '--tenant \$env:AZURE_TENANT_ID'
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
        $bootstrap | Should -Match "Invoke-Graph GET 'policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass' -Beta"
        $bootstrap | Should -Match '\$includeTargets = @\(\$currentTap.includeTargets\)'
        $bootstrap | Should -Not -Match 'defaultLifetimeInMinutes = 120'
    }

    It 'fails the Logic App after processing when any policy patch fails' {
        $logicApp | Should -Match "name: 'PatchFailures'"
        $logicApp | Should -Match "type: 'AppendToArrayVariable'"
        $logicApp | Should -Match "type: 'Terminate'"
        $logicApp | Should -Match "runStatus: 'Failed'"
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
}
