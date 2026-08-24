BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'scripts/vendor/Azd.DeploymentValidation/Azd.DeploymentValidation.psd1') -Force
    Import-Module (Join-Path $repoRoot 'scripts/Deployment.Validation.psm1') -Force
}

Describe 'Portfolio deployment validation' {
    It 'defines nine stable checks with explicit side effects and dependencies' {
        $definitions = @(Get-ProjectValidationDefinition)

        $definitions.Count | Should -Be 9
        @($definitions.id | Select-Object -Unique).Count | Should -Be 9
        @($definitions | Where-Object sideEffect -eq 'syntheticDelivery').id |
            Should -Be @('delivery.sentinel-notification')
        @($definitions | Where-Object sideEffect -eq 'negativeProbe').id |
            Should -Be @('security.sentinel-function-authentication')
        ($definitions | Where-Object id -eq 'delivery.sentinel-notification').dependsOn |
            Should -Contain 'configuration.sentinel-resources'
    }

    It 'plans without Azure, HTTP, sleep, or delivery calls' {
        Mock az { throw 'Azure CLI must not run in Plan mode.' }
        Mock Invoke-WebRequest { throw 'HTTP must not run in Plan mode.' }
        Mock Start-Sleep { throw 'Polling must not run in Plan mode.' }

        $report = & (Join-Path $repoRoot 'scripts/Test-Deployment.ps1') -Plan -PassThru `
            -OutputPath 'reports/pester-plan.json'

        $report.mode | Should -Be 'plan'
        $report.outcome | Should -Be 'planned'
        $report.summary.planned | Should -Be 9
        Assert-MockCalled az -Times 0 -Exactly
        Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly
        Assert-MockCalled Start-Sleep -Times 0 -Exactly
    }

    It 'fails context before Azure access when a persisted deployment decision is missing' {
        InModuleScope Deployment.Validation {
            Mock Get-AzdEnvironmentValue
            Mock Assert-AzdTenantContext { throw 'Azure context must not be checked.' }
            $values = [ordered]@{
                AZURE_SUBSCRIPTION_ID = '11111111-1111-4111-8111-111111111111'
                AZURE_TENANT_ID = '22222222-2222-4222-8222-222222222222'
                AZD_DEPLOYMENT_MODE = 'function-scheduled'
                AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT = 'false'
                AZD_ENABLE_SIGNIN_ALERTS = $null
                AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS = 'false'
            }
            $oldValues = @{}
            try {
                foreach ($entry in $values.GetEnumerator()) {
                    $oldValues[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key)
                    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
                }
                $definition = Get-ProjectValidationDefinition | Where-Object id -eq 'context.azure-session'
                $action = $definition.action
                $outcome = & $action
            }
            finally {
                foreach ($entry in $oldValues.GetEnumerator()) {
                    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
                }
            }

            $outcome.status | Should -Be 'fail'
            $outcome.actual.failureCode | Should -Be 'context.requiredValueMissing'
            @($outcome.actual.missingValueNames) | Should -Contain 'AZD_ENABLE_SIGNIN_ALERTS'
            Assert-MockCalled Assert-AzdTenantContext -Times 0 -Exactly
        }
    }

    It 'rejects unsupported deployment modes before Azure access' {
        InModuleScope Deployment.Validation {
            Mock Get-AzdEnvironmentValue
            Mock Assert-AzdTenantContext { throw 'Azure context must not be checked.' }
            $values = [ordered]@{
                AZURE_SUBSCRIPTION_ID = '11111111-1111-4111-8111-111111111111'
                AZURE_TENANT_ID = '22222222-2222-4222-8222-222222222222'
                AZD_DEPLOYMENT_MODE = 'unsupported'
                AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT = 'false'
                AZD_ENABLE_SIGNIN_ALERTS = 'false'
                AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS = 'false'
            }
            $oldValues = @{}
            try {
                foreach ($entry in $values.GetEnumerator()) {
                    $oldValues[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key)
                    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
                }
                $definition = Get-ProjectValidationDefinition | Where-Object id -eq 'context.azure-session'
                $action = $definition.action
                $outcome = & $action
            }
            finally {
                foreach ($entry in $oldValues.GetEnumerator()) {
                    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
                }
            }

            $outcome.status | Should -Be 'fail'
            $outcome.actual.failureCode | Should -Be 'context.deploymentModeInvalid'
            Assert-MockCalled Assert-AzdTenantContext -Times 0 -Exactly
        }
    }

    It 'rejects malformed feature decisions before Azure access' {
        InModuleScope Deployment.Validation {
            Mock Get-AzdEnvironmentValue
            Mock Assert-AzdTenantContext { throw 'Azure context must not be checked.' }
            $values = [ordered]@{
                AZURE_SUBSCRIPTION_ID = '11111111-1111-4111-8111-111111111111'
                AZURE_TENANT_ID = '22222222-2222-4222-8222-222222222222'
                AZD_DEPLOYMENT_MODE = 'function-scheduled'
                AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT = 'false'
                AZD_ENABLE_SIGNIN_ALERTS = 'sometimes'
                AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS = 'false'
            }
            $oldValues = @{}
            try {
                foreach ($entry in $values.GetEnumerator()) {
                    $oldValues[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key)
                    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
                }
                $definition = Get-ProjectValidationDefinition | Where-Object id -eq 'context.azure-session'
                $action = $definition.action
                $outcome = & $action
            }
            finally {
                foreach ($entry in $oldValues.GetEnumerator()) {
                    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
                }
            }

            $outcome.status | Should -Be 'fail'
            $outcome.actual.failureCode | Should -Be 'context.featureDecisionInvalid'
            @($outcome.actual.invalidValueNames) | Should -Contain 'AZD_ENABLE_SIGNIN_ALERTS'
            Assert-MockCalled Assert-AzdTenantContext -Times 0 -Exactly
        }
    }

    It 'gates every cloud, probe, and delivery action after context failure' {
        InModuleScope Deployment.Validation {
            Mock Assert-AzdTenantContext { throw 'simulated context failure' }
            Mock Get-AzdEnvironmentValue
            Mock az { throw 'Azure CLI must remain gated.' }
            Mock Invoke-WebRequest { throw 'HTTP must remain gated.' }
            Mock Test-EmergencySentinelFunctionAuthentication { throw 'Function probe must remain gated.' }
            Mock Invoke-EmergencySentinelNotificationDelivery { throw 'Delivery must remain gated.' }

            $oldSubscription = $env:AZURE_SUBSCRIPTION_ID
            $oldTenant = $env:AZURE_TENANT_ID
            try {
                $env:AZURE_SUBSCRIPTION_ID = '11111111-1111-4111-8111-111111111111'
                $env:AZURE_TENANT_ID = '22222222-2222-4222-8222-222222222222'
                $results = @(Invoke-AzdValidationSet -Definitions @(Get-ProjectValidationDefinition) `
                        -AllowSyntheticDelivery)
            }
            finally {
                $env:AZURE_SUBSCRIPTION_ID = $oldSubscription
                $env:AZURE_TENANT_ID = $oldTenant
            }

            ($results | Where-Object id -eq 'context.azure-session').status | Should -Be 'fail'
            foreach ($id in @(
                    'infrastructure.resource-group',
                    'configuration.signin-alerts',
                    'configuration.sentinel-resources',
                    'security.sentinel-function-authentication',
                    'delivery.sentinel-notification'
                )) {
                ($results | Where-Object id -eq $id).status | Should -Be 'skipped'
            }
            Assert-MockCalled az -Times 0 -Exactly
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly
            Assert-MockCalled Test-EmergencySentinelFunctionAuthentication -Times 0 -Exactly
            Assert-MockCalled Invoke-EmergencySentinelNotificationDelivery -Times 0 -Exactly
        }
    }

    It 'uses TestDelivery as the only synthetic-delivery gate' {
        $wrapper = Get-Content (Join-Path $repoRoot 'scripts/Test-Deployment.ps1') -Raw
        $postProvision = Get-Content (Join-Path $repoRoot 'scripts/Post-Provision.ps1') -Raw
        $validation = Get-Content (Join-Path $repoRoot 'scripts/Validate-Environment.ps1') -Raw

        $wrapper | Should -Match 'AllowSyntheticDelivery:\$TestDelivery'
        $postProvision | Should -Match 'Test-Deployment\.ps1" -TestDelivery'
        $validation | Should -Not -Match 'AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY'
    }

    It 'returns one structured delivery outcome when multiple destination actions are verified' {
        InModuleScope Deployment.Validation {
            Mock Invoke-EmergencySentinelNotificationDelivery {
                @('Post_message_to_Teams_channel', 'Send_incident_email')
            }

            $oldEnabled = $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS
            $oldPlaybook = $env:AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID
            try {
                $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS = 'true'
                $env:AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID = '/subscriptions/test/resourceGroups/test/providers/Microsoft.Logic/workflows/test'
                $definition = Get-ProjectValidationDefinition |
                    Where-Object id -eq 'delivery.sentinel-notification'
                $action = $definition.action
                $outcomes = @(& $action)
            }
            finally {
                $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS = $oldEnabled
                $env:AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID = $oldPlaybook
            }

            $outcomes.Count | Should -Be 1
            $outcomes[0].PSTypeNames | Should -Contain 'Azd.Validation.CheckOutcome'
            $outcomes[0].status | Should -Be 'pass'
            @($outcomes[0].evidence.verifiedActionNames) |
                Should -Be @('Post_message_to_Teams_channel', 'Send_incident_email')
            Assert-MockCalled Invoke-EmergencySentinelNotificationDelivery -Times 1 -Exactly
        }
    }

    It 'matches every vendored file to deployment-validation 0.3.2' {
        $lock = Get-Content (Join-Path $repoRoot 'azd-components.lock.json') -Raw | ConvertFrom-Json
        $component = @($lock.components | Where-Object id -eq 'deployment-validation')

        $component.Count | Should -Be 1
        $component[0].version | Should -Be '0.3.2'
        $component[0].sourceRevision | Should -Match '^[0-9a-f]{40}$'
        foreach ($file in $component[0].files) {
            $actual = (Get-FileHash -LiteralPath (Join-Path $repoRoot $file.target) -Algorithm SHA256).Hash.ToLowerInvariant()
            $actual | Should -Be $file.sha256
        }
    }
}
