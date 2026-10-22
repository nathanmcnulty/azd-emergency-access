Describe 'Hosted PowerShell LTS selections' {
    BeforeAll {
        $repoRoot = Join-Path $PSScriptRoot '..'
        $flex = Get-Content (Join-Path $repoRoot 'infra/modules/function-flex.bicep') -Raw
        $automation = Get-Content (Join-Path $repoRoot 'infra/modes/automation-scheduled.bicep') -Raw
        $template = Get-Content (Join-Path $repoRoot 'infra/main.json') -Raw | ConvertFrom-Json -Depth 100
        function Get-TemplateResource {
            param($Template)
            foreach ($resource in @($Template.resources)) {
                $resource
                if ($resource.properties.template) { Get-TemplateResource $resource.properties.template }
            }
        }
        $resources = @(Get-TemplateResource $template)
    }

    It 'selects PowerShell 7.6 in the shared Flex module and both compiled consumers' {
        $flex | Should -Match "runtime:\s*\{\s*name: 'powershell'\s*version: '7\.6'"
        $apps = @($resources | Where-Object type -EQ 'Microsoft.Web/sites')
        $apps.Count | Should -Be 2
        foreach ($app in $apps) {
            $app.properties.functionAppConfig.runtime.name | Should -Be 'powershell'
            $app.properties.functionAppConfig.runtime.version | Should -Be '7.6'
        }
    }

    It 'binds the compiled runbook to the new PowerShell 7.6 environment' {
        $automation | Should -Match "runtimeEnvironment: runtime\.name"
        $runtimes = @($resources | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runtimeEnvironments')
        $runtimes.Count | Should -Be 1
        $runtimes[0].name | Should -Match 'PowerShell-7-6'
        $runtimes[0].properties.runtime.language | Should -Be 'PowerShell'
        $runtimes[0].properties.runtime.version | Should -Be '7.6'
        $runbooks = @($resources | Where-Object type -EQ 'Microsoft.Automation/automationAccounts/runbooks')
        $runbooks.Count | Should -Be 1
        $runbooks[0].properties.runtimeEnvironment | Should -Be 'PowerShell-7-6'
        $runtimes[0].properties.defaultPackages.Az | Should -Be '15.1.0'
    }
}
