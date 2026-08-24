@{
    RootModule = 'Azd.GraphAuthentication.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'ac65e94a-6112-4ff8-820d-9ed639c8dc3e'
    Author = 'Nathan McNulty'
    CompanyName = 'Community'
    Copyright = 'Released into the public domain under the Unlicense.'
    Description = 'One-login delegated Microsoft Graph session coordination for azd solutions.'
    PowerShellVersion = '7.2'
    RequiredModules = @(
        @{ ModuleName = 'Microsoft.Graph.Authentication'; ModuleVersion = '2.30.0' }
    )
    FunctionsToExport = @(
        'Connect-AzdGraphSession',
        'Resolve-AzdGraphScopeSet'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('azd', 'MicrosoftGraph', 'authentication')
            ProjectUri = 'https://github.com/nathanmcnulty/azd-reference'
            LicenseUri = 'https://unlicense.org/'
        }
    }
}
