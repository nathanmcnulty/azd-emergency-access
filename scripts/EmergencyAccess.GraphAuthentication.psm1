Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'vendor/Azd.GraphAuthentication/Azd.GraphAuthentication.psd1') -Force

function Get-EmergencyAccessGraphScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $ManageEmergencyIdentities,
        [Parameter(Mandatory)][string] $DeploymentMode,
        [Parameter(Mandatory)][bool] $EnableTapPolicy
    )

    $scopes = [Collections.Generic.List[string]]::new()
    if ($ManageEmergencyIdentities) {
        @(
            'User.ReadWrite.All',
            'Group.ReadWrite.All',
            'AdministrativeUnit.ReadWrite.All',
            'RoleManagement.ReadWrite.Directory',
            'User.RevokeSessions.All'
        ) | ForEach-Object { $scopes.Add($_) }
    }
    else {
        $scopes.Add('User.Read.All')
        $scopes.Add('Group.Read.All')
    }
    @(
        'Application.Read.All',
        'AppRoleAssignment.ReadWrite.All',
        'Policy.ReadWrite.ConditionalAccess'
    ) | ForEach-Object { $scopes.Add($_) }
    if ($DeploymentMode -eq 'sentinel-function') {
        $scopes.Add('Application.ReadWrite.All')
    }
    if ($EnableTapPolicy) {
        $scopes.Add('Policy.ReadWrite.AuthenticationMethod')
        $scopes.Add('UserAuthenticationMethod.ReadWrite.All')
    }
    elseif ($ManageEmergencyIdentities) {
        $scopes.Add('Policy.Read.AuthenticationMethod')
        $scopes.Add('UserAuthenticationMethod.Read.All')
    }
    return @(Resolve-AzdGraphScopeSet -Scope $scopes)
}

function Get-EmergencyAccessGraphOperatorContext {
    [CmdletBinding()]
    param()

    $azureContext = Assert-AzdTenantContext -PassThru
    if ([string] $azureContext.environmentName -ine 'AzureCloud') {
        throw "azd-emergency-access currently supports the AzureCloud and Microsoft Graph Global environments only. Active Azure environment: '$($azureContext.environmentName)'."
    }

    $configuredAccount = [string] $env:AZD_GRAPH_OPERATOR_UPN
    $azureAccount = if ([string] $azureContext.user.type -ieq 'user') {
        [string] $azureContext.user.name
    }
    else {
        $null
    }
    if ($configuredAccount -and $azureAccount -and $configuredAccount -ine $azureAccount) {
        throw "AZD_GRAPH_OPERATOR_UPN '$configuredAccount' does not match the selected Azure CLI user '$azureAccount'."
    }
    $expectedAccount = if ($configuredAccount) { $configuredAccount } else { $azureAccount }
    if ($expectedAccount -notmatch '^[^@\s]+@[^@\s]+$') {
        throw 'A delegated Microsoft Graph administrator UPN is required. Sign in to Azure CLI as that user or set AZD_GRAPH_OPERATOR_UPN for a non-user Azure CLI context.'
    }

    return [pscustomobject] [ordered]@{
        tenantId = [guid] $azureContext.tenantId
        account = $expectedAccount
        environment = 'Global'
    }
}

function Connect-EmergencyAccessGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]] $Scopes,
        [Parameter(Mandatory)][string] $ProbeUri,
        [switch] $AllowInteractive,
        [switch] $AllowContextReplacement
    )

    $operator = Get-EmergencyAccessGraphOperatorContext
    return Connect-AzdGraphSession `
        -TenantId $operator.tenantId `
        -ExpectedAccount $operator.account `
        -Environment $operator.environment `
        -Scopes $Scopes `
        -ProbeUri $ProbeUri `
        -AllowInteractive:$AllowInteractive `
        -AllowContextReplacement:$AllowContextReplacement
}

function Connect-EmergencyAccessBootstrapGraph {
    [CmdletBinding()]
    param(
        [switch] $AllowInteractive,
        [switch] $AllowContextReplacement
    )

    $scopes = Get-EmergencyAccessGraphScope `
        -ManageEmergencyIdentities ($env:AZD_MANAGE_EMERGENCY_IDENTITIES -eq 'true') `
        -DeploymentMode $env:AZD_DEPLOYMENT_MODE `
        -EnableTapPolicy ($env:AZD_ENABLE_TAP_POLICY -eq 'true')
    return Connect-EmergencyAccessGraph `
        -Scopes $scopes `
        -ProbeUri '/v1.0/users?$top=1&$select=id' `
        -AllowInteractive:$AllowInteractive `
        -AllowContextReplacement:$AllowContextReplacement
}

Export-ModuleMember -Function @(
    'Get-EmergencyAccessGraphScope',
    'Get-EmergencyAccessGraphOperatorContext',
    'Connect-EmergencyAccessGraph',
    'Connect-EmergencyAccessBootstrapGraph'
)
