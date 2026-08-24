[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Cleanup.Guards.psm1" -Force
Import-Module "$PSScriptRoot\Tenant.Guards.psm1" -Force
Import-Module "$PSScriptRoot\EmergencyAccess.GraphAuthentication.psm1" -Force
Assert-AzdTenantContext

function Get-AccessToken {
    param(
        [Parameter(Mandatory)][string] $Resource,
        [Parameter(Mandatory)][string] $SubscriptionId
    )
    $token = & az account get-access-token --subscription $SubscriptionId `
        --resource $Resource --query accessToken -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "Unable to acquire an access token for $Resource."
    }
    return $token
}

function Remove-RestResource {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][hashtable] $Headers
    )
    try {
        Invoke-RestMethod -Method DELETE -Uri $Uri -Headers $Headers
    }
    catch {
        if ([int]$_.Exception.Response.StatusCode -ne 404) {
            throw
        }
    }
}

function Remove-GraphResource {
    param([Parameter(Mandatory)][string] $Uri)

    try {
        Invoke-MgGraphRequest -Method DELETE -Uri $Uri -ErrorAction Stop | Out-Null
    }
    catch {
        $responseProperty = $_.Exception.PSObject.Properties['Response']
        $response = if ($responseProperty) { $responseProperty.Value } else { $null }
        $statusCode = if ($response -and $response.PSObject.Properties['StatusCode']) {
            [int] $response.StatusCode
        }
        else {
            0
        }
        if ($statusCode -ne 404) {
            throw
        }
    }
}

function Clear-AzdEnvironmentValue {
    param([Parameter(Mandatory)][string] $Name)
    & azd env set $Name '' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to clear ownership record $Name."
    }
}

if ($env:AZD_OWNED_SENTINEL_ALERT_RULE_ID -or
    $env:AZD_OWNED_SENTINEL_AUTOMATION_RULE_ID -or
    $env:AZD_OWNED_SENTINEL_SIGNIN_RULE_ID -or
    $env:AZD_OWNED_SENTINEL_ADMIN_ACTIVITY_RULE_ID -or
    $env:AZD_OWNED_SENTINEL_ACCOUNT_CHANGE_RULE_ID -or
    $env:AZD_OWNED_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID -or
    $env:AZD_OWNED_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID) {
    $sentinelSubscriptionId = if ($env:AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID) {
        $env:AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID
    }
    else {
        $env:AZURE_SUBSCRIPTION_ID
    }
    $armToken = Get-AccessToken `
        -Resource 'https://management.azure.com/' `
        -SubscriptionId $sentinelSubscriptionId
    $armHeaders = @{ Authorization = "Bearer $armToken" }
    $rules = @(
        @{
            Name = 'AZD_OWNED_SENTINEL_AUTOMATION_RULE_ID'
            Id = $env:AZD_OWNED_SENTINEL_AUTOMATION_RULE_ID
            Type = 'automationRules'
            ApiVersion = '2024-09-01'
        },
        @{
            Name = 'AZD_OWNED_SENTINEL_ALERT_RULE_ID'
            Id = $env:AZD_OWNED_SENTINEL_ALERT_RULE_ID
            Type = 'alertRules'
            ApiVersion = '2024-01-01-preview'
        },
        @{
            Name = 'AZD_OWNED_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID'
            Id = $env:AZD_OWNED_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID
            Type = 'automationRules'
            ApiVersion = '2024-09-01'
        },
        @{
            Name = 'AZD_OWNED_SENTINEL_SIGNIN_RULE_ID'
            Id = $env:AZD_OWNED_SENTINEL_SIGNIN_RULE_ID
            Type = 'alertRules'
            ApiVersion = '2024-01-01-preview'
        },
        @{
            Name = 'AZD_OWNED_SENTINEL_ADMIN_ACTIVITY_RULE_ID'
            Id = $env:AZD_OWNED_SENTINEL_ADMIN_ACTIVITY_RULE_ID
            Type = 'alertRules'
            ApiVersion = '2024-01-01-preview'
        },
        @{
            Name = 'AZD_OWNED_SENTINEL_ACCOUNT_CHANGE_RULE_ID'
            Id = $env:AZD_OWNED_SENTINEL_ACCOUNT_CHANGE_RULE_ID
            Type = 'alertRules'
            ApiVersion = '2024-01-01-preview'
        },
        @{
            Name = 'AZD_OWNED_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID'
            Id = $env:AZD_OWNED_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID
            Type = 'roleAssignments'
            ApiVersion = '2022-04-01'
        }
    )
    foreach ($rule in $rules) {
        if (-not $rule.Id) {
            continue
        }
        $isOwned = if ($rule.Type -eq 'roleAssignments') {
            Test-OwnedWorkspaceRoleAssignmentId `
                -ResourceId $rule.Id `
                -SubscriptionId $sentinelSubscriptionId `
                -ResourceGroup $env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP `
                -WorkspaceName $env:AZD_SENTINEL_WORKSPACE_NAME
        }
        else {
            Test-OwnedSentinelResourceId `
                -ResourceId $rule.Id `
                -SubscriptionId $sentinelSubscriptionId `
                -ResourceGroup $env:AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP `
                -WorkspaceName $env:AZD_SENTINEL_WORKSPACE_NAME `
                -ResourceType $rule.Type
        }
        if (-not $isOwned) {
            throw "$($rule.Name) failed ownership validation; refusing cross-scope deletion."
        }
        $expectedIdName = $rule.Name.Replace('AZD_OWNED_', 'AZD_')
        $expectedId = [Environment]::GetEnvironmentVariable($expectedIdName)
        if (-not $expectedId -or $rule.Id -ne $expectedId) {
            throw "$($rule.Name) does not exactly match deterministic resource record $expectedIdName; refusing deletion."
        }
        Remove-RestResource `
            -Uri "https://management.azure.com$($rule.Id)?api-version=$($rule.ApiVersion)" `
            -Headers $armHeaders
        Clear-AzdEnvironmentValue $rule.Name
        if ($rule.Type -eq 'roleAssignments') {
            Clear-AzdEnvironmentValue $expectedIdName
        }
    }
    $armToken = $null
}

$ownedClientId = $env:AZD_OWNED_FUNCTION_AUTH_CLIENT_ID
if ($ownedClientId) {
    if ($env:AZD_FUNCTION_AUTH_CLIENT_ID -and
        -not (Test-OwnedObjectId -CurrentId $env:AZD_FUNCTION_AUTH_CLIENT_ID -OwnedId $ownedClientId)) {
        throw 'Function authentication app ownership no longer matches the configured client ID; refusing deletion.'
    }

    $applicationObjectId = $env:AZD_OWNED_FUNCTION_AUTH_APPLICATION_OBJECT_ID
    $parsedApplicationId = [guid]::Empty
    if (-not [guid]::TryParse($applicationObjectId, [ref]$parsedApplicationId)) {
        throw 'Function authentication application ownership record is invalid; refusing deletion.'
    }

    $allowInteractiveGraph = -not (
        $env:CI -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected
    )
    Connect-EmergencyAccessGraph `
        -Scopes @('Application.ReadWrite.All') `
        -ProbeUri '/v1.0/applications?$top=1&$select=id' `
        -AllowInteractive:$allowInteractiveGraph `
        -AllowContextReplacement:$allowInteractiveGraph | Out-Null
    if ($env:AZD_OWNED_FUNCTION_AUTH_SERVICE_PRINCIPAL_ID) {
        $parsedServicePrincipalId = [guid]::Empty
        if (-not [guid]::TryParse(
            $env:AZD_OWNED_FUNCTION_AUTH_SERVICE_PRINCIPAL_ID,
            [ref]$parsedServicePrincipalId
        )) {
            throw 'Function authentication service-principal ownership record is invalid; refusing deletion.'
        }
        Remove-GraphResource `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($env:AZD_OWNED_FUNCTION_AUTH_SERVICE_PRINCIPAL_ID)"
    }
    Remove-GraphResource `
        -Uri "https://graph.microsoft.com/v1.0/applications/$applicationObjectId"

    foreach ($name in @(
        'AZD_FUNCTION_AUTH_CLIENT_ID',
        'AZD_FUNCTION_AUTH_AUDIENCE',
        'AZD_OWNED_FUNCTION_AUTH_APPLICATION_OBJECT_ID',
        'AZD_OWNED_FUNCTION_AUTH_SERVICE_PRINCIPAL_ID',
        'AZD_OWNED_FUNCTION_AUTH_CLIENT_ID',
        'AZD_OWNED_FUNCTION_AUTH_AUDIENCE',
        'AZD_OWNED_FUNCTION_AUTH_APP_ROLE_ID'
    )) {
        Clear-AzdEnvironmentValue $name
    }
}

Clear-AzdEnvironmentValue 'AZD_PROVISIONED_MODE'
Clear-AzdEnvironmentValue 'AZD_SENTINEL_TEAMS_AUTHORIZED'
