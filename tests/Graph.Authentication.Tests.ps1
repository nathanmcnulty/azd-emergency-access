BeforeAll {
    $script:repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.30.0 -Force
    Import-Module (Join-Path $repoRoot 'scripts/EmergencyAccess.GraphAuthentication.psm1') -Force
    Import-Module (Join-Path $repoRoot 'scripts/vendor/Azd.GraphAuthentication/Azd.GraphAuthentication.psd1') -Force
    $script:tenantId = [guid] 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    $script:expectedAccount = 'admin@example.com'
}

Describe 'Emergency Access Graph scope planning' {
    It 'consolidates every enabled managed Sentinel and TAP permission once' {
        $scopes = @(Get-EmergencyAccessGraphScope `
                -ManageEmergencyIdentities $true `
                -DeploymentMode sentinel-function `
                -EnableTapPolicy $true)

        foreach ($scope in @(
                'User.ReadWrite.All',
                'Group.ReadWrite.All',
                'AdministrativeUnit.ReadWrite.All',
                'RoleManagement.ReadWrite.Directory',
                'User.RevokeSessions.All',
                'Application.Read.All',
                'Application.ReadWrite.All',
                'AppRoleAssignment.ReadWrite.All',
                'Policy.ReadWrite.ConditionalAccess',
                'Policy.ReadWrite.AuthenticationMethod',
                'UserAuthenticationMethod.ReadWrite.All'
            )) {
            $scopes | Should -Contain $scope
        }
        @($scopes | Sort-Object -Unique).Count | Should -Be $scopes.Count
    }

    It 'uses the reduced read scope set for externally managed identities' {
        $scopes = @(Get-EmergencyAccessGraphScope `
                -ManageEmergencyIdentities $false `
                -DeploymentMode function-scheduled `
                -EnableTapPolicy $false)

        $scopes | Should -Contain 'User.Read.All'
        $scopes | Should -Contain 'Group.Read.All'
        $scopes | Should -Contain 'Policy.ReadWrite.ConditionalAccess'
        $scopes | Should -Not -Contain 'User.ReadWrite.All'
        $scopes | Should -Not -Contain 'Application.ReadWrite.All'
        $scopes | Should -Not -Contain 'Policy.ReadWrite.AuthenticationMethod'
    }
}

Describe 'Emergency Access shared Graph adapter' {
    BeforeEach {
        Mock Get-EmergencyAccessGraphOperatorContext -ModuleName EmergencyAccess.GraphAuthentication {
            [pscustomobject]@{
                tenantId = $tenantId
                account = $expectedAccount
                environment = 'Global'
            }
        }
        Mock Connect-AzdGraphSession -ModuleName EmergencyAccess.GraphAuthentication {
            [pscustomobject]@{
                tenantId = $TenantId.Guid
                account = $ExpectedAccount
                grantedScopes = @($Scopes)
                connectInvoked = [bool] $AllowInteractive
                contextReused = -not [bool] $AllowInteractive
                probeSucceeded = $true
            }
        }
    }

    It 'makes one explicitly authorized shared call with exact tenant account cloud scopes and probe' {
        $scopes = @('User.Read.All', 'Group.Read.All')

        Connect-EmergencyAccessGraph `
            -Scopes $scopes `
            -ProbeUri '/v1.0/users?$top=1&$select=id' `
            -AllowInteractive `
            -AllowContextReplacement | Out-Null

        Should -Invoke Connect-AzdGraphSession -ModuleName EmergencyAccess.GraphAuthentication -Times 1 -Exactly -ParameterFilter {
            $TenantId -eq $script:tenantId -and
            $ExpectedAccount -eq $script:expectedAccount -and
            $Environment -eq 'Global' -and
            $ProbeUri -eq '/v1.0/users?$top=1&$select=id' -and
            $AllowInteractive -and
            $AllowContextReplacement -and
            @($Scopes).Count -eq 2
        }
    }

    It 'does not authorize interaction or inherited-context replacement for noninteractive execution' {
        Connect-EmergencyAccessGraph `
            -Scopes @('User.Read.All') `
            -ProbeUri '/v1.0/users?$top=1&$select=id' | Out-Null

        Should -Invoke Connect-AzdGraphSession -ModuleName EmergencyAccess.GraphAuthentication -Times 1 -Exactly -ParameterFilter {
            -not $AllowInteractive -and -not $AllowContextReplacement
        }
    }
}

Describe 'Emergency Access operator binding' {
    BeforeEach {
        $env:AZD_GRAPH_OPERATOR_UPN = $null
    }

    AfterEach {
        $env:AZD_GRAPH_OPERATOR_UPN = $null
    }

    It 'derives the exact administrator from the validated AzureCloud user context' {
        Mock Assert-AzdTenantContext -ModuleName EmergencyAccess.GraphAuthentication {
            [pscustomobject]@{
                id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                tenantId = $tenantId.Guid
                environmentName = 'AzureCloud'
                user = [pscustomobject]@{ type = 'user'; name = $expectedAccount }
            }
        }

        $operator = Get-EmergencyAccessGraphOperatorContext

        $operator.tenantId | Should -Be $tenantId
        $operator.account | Should -Be $expectedAccount
        $operator.environment | Should -Be 'Global'
    }

    It 'requires an explicit delegated administrator for an Azure workload identity' {
        Mock Assert-AzdTenantContext -ModuleName EmergencyAccess.GraphAuthentication {
            [pscustomobject]@{
                tenantId = $tenantId.Guid
                environmentName = 'AzureCloud'
                user = [pscustomobject]@{ type = 'servicePrincipal'; name = 'application-id' }
            }
        }

        { Get-EmergencyAccessGraphOperatorContext } | Should -Throw '*AZD_GRAPH_OPERATOR_UPN*'
    }

    It 'rejects a configured account that differs from the Azure CLI user' {
        $env:AZD_GRAPH_OPERATOR_UPN = 'different@example.com'
        Mock Assert-AzdTenantContext -ModuleName EmergencyAccess.GraphAuthentication {
            [pscustomobject]@{
                tenantId = $tenantId.Guid
                environmentName = 'AzureCloud'
                user = [pscustomobject]@{ type = 'user'; name = $expectedAccount }
            }
        }

        { Get-EmergencyAccessGraphOperatorContext } | Should -Throw '*does not match*'
    }

    It 'fails closed outside the project supported Azure and Graph cloud' {
        Mock Assert-AzdTenantContext -ModuleName EmergencyAccess.GraphAuthentication {
            [pscustomobject]@{
                tenantId = $tenantId.Guid
                environmentName = 'AzureUSGovernment'
                user = [pscustomobject]@{ type = 'user'; name = $expectedAccount }
            }
        }

        { Get-EmergencyAccessGraphOperatorContext } | Should -Throw '*AzureCloud*Global*'
    }
}

Describe 'vendored Graph authentication contract' {
    It 'reuses a matching delegated CurrentUser context after one harmless probe and no login' {
        $scopes = @('User.Read.All', 'Group.Read.All')
        $context = [pscustomobject]@{
            TenantId = $tenantId.Guid
            Environment = 'Global'
            AuthType = 'Delegated'
            ContextScope = 'CurrentUser'
            Account = $expectedAccount
            Scopes = $scopes
        }
        Mock Get-MgEnvironment -ModuleName Azd.GraphAuthentication { [pscustomobject]@{ Name = 'Global' } }
        Mock Get-MgContext -ModuleName Azd.GraphAuthentication { $context }
        Mock Invoke-MgGraphRequest -ModuleName Azd.GraphAuthentication { [pscustomobject]@{ id = 'probe' } }
        Mock Connect-MgGraph -ModuleName Azd.GraphAuthentication

        $result = Connect-AzdGraphSession `
            -TenantId $tenantId `
            -ExpectedAccount $expectedAccount `
            -Environment Global `
            -Scopes $scopes `
            -ProbeUri '/v1.0/users?$top=1&$select=id'

        $result.contextReused | Should -BeTrue
        $result.connectInvoked | Should -BeFalse
        Should -Invoke Invoke-MgGraphRequest -ModuleName Azd.GraphAuthentication -Times 1 -Exactly
        Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 0 -Exactly
    }

    It 'uses at most one interactive call to establish and prove the selected administrator context' {
        $scopes = @('User.Read.All', 'Group.Read.All')
        $global:AzdEmergencyAccessTestGraphContext = $null
        $global:AzdEmergencyAccessTestMatchingContext = [pscustomobject]@{
            TenantId = $tenantId.Guid
            Environment = 'Global'
            AuthType = 'Delegated'
            ContextScope = 'CurrentUser'
            Account = $expectedAccount
            Scopes = $scopes
        }
        try {
            Mock Get-MgEnvironment -ModuleName Azd.GraphAuthentication { [pscustomobject]@{ Name = 'Global' } }
            Mock Get-MgContext -ModuleName Azd.GraphAuthentication { $global:AzdEmergencyAccessTestGraphContext }
            Mock Connect-MgGraph -ModuleName Azd.GraphAuthentication {
                $global:AzdEmergencyAccessTestGraphContext = $global:AzdEmergencyAccessTestMatchingContext
            }
            Mock Invoke-MgGraphRequest -ModuleName Azd.GraphAuthentication { [pscustomobject]@{ id = 'probe' } }

            $result = Connect-AzdGraphSession `
                -TenantId $tenantId `
                -ExpectedAccount $expectedAccount `
                -Environment Global `
                -Scopes $scopes `
                -ProbeUri '/v1.0/users?$top=1&$select=id' `
                -AllowInteractive `
                -AllowContextReplacement

            $result.contextReused | Should -BeFalse
            $result.connectInvoked | Should -BeTrue
            Should -Invoke Connect-MgGraph -ModuleName Azd.GraphAuthentication -Times 1 -Exactly
            Should -Invoke Invoke-MgGraphRequest -ModuleName Azd.GraphAuthentication -Times 1 -Exactly
        }
        finally {
            Remove-Variable AzdEmergencyAccessTestGraphContext -Scope Global -ErrorAction SilentlyContinue
            Remove-Variable AzdEmergencyAccessTestMatchingContext -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'matches the graph-delegated-authentication lock revision and file hashes' {
        $lock = Get-Content (Join-Path $repoRoot 'azd-components.lock.json') -Raw | ConvertFrom-Json
        $component = @($lock.components | Where-Object id -eq 'graph-delegated-authentication')

        $component.Count | Should -Be 1
        $component[0].sourceRevision | Should -Match '^[0-9a-f]{40}$'
        $moduleFile = @($component[0].files | Where-Object target -eq 'scripts/vendor/Azd.GraphAuthentication/Azd.GraphAuthentication.psd1')
        $moduleFile.Count | Should -Be 1
        $moduleManifest = Import-PowerShellDataFile -LiteralPath (Join-Path $repoRoot $moduleFile[0].target)
        $moduleManifest.ModuleVersion.ToString() | Should -Be $component[0].version
        foreach ($file in @($component[0].files)) {
            $actual = (Get-FileHash -LiteralPath (Join-Path $repoRoot $file.target) -Algorithm SHA256).Hash.ToLowerInvariant()
            $actual | Should -Be $file.sha256
        }
    }

    It 'contains no delegated Graph Azure CLI token fallback or alternate device flow' {
        $source = @(
            'scripts/Bootstrap-Tenant.ps1',
            'scripts/Pre-Down.ps1',
            'scripts/Remove-TenantObjects.ps1',
            'scripts/EmergencyAccess.GraphAuthentication.psm1',
            'scripts/vendor/Azd.GraphAuthentication/Azd.GraphAuthentication.psm1'
        ) | ForEach-Object { Get-Content (Join-Path $repoRoot $_) -Raw }
        $source = $source -join "`n"

        $source | Should -Not -Match "-Resource 'https://graph.microsoft.com/'|--resource-type\s+ms-graph"
        $source | Should -Not -Match '(?i)UseDeviceAuthentication|UseDeviceCode|DeviceCodeCredential|Disconnect-MgGraph'
    }
}
