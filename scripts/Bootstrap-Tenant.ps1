[CmdletBinding()]
param(
    [ValidateSet('All', 'Identities', 'Workload')]
    [string] $Phase = 'All'
)

$ErrorActionPreference = 'Stop'
$graphRoot = 'https://graph.microsoft.com'
Import-Module "$PSScriptRoot\Tenant.Guards.psm1" -Force
Assert-AzdTenantContext

function Test-Interactive {
    return -not ($env:CI -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected)
}

function Connect-ProjectGraph {
    $scopes = [Collections.Generic.List[string]]::new()
    @(
        'User.ReadWrite.All',
        'Group.ReadWrite.All',
        'AdministrativeUnit.ReadWrite.All',
        'RoleManagement.ReadWrite.Directory',
        'Application.Read.All',
        'AppRoleAssignment.ReadWrite.All',
        'Policy.ReadWrite.ConditionalAccess'
    ) | ForEach-Object { $scopes.Add($_) }
    if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function') {
        $scopes.Add('Application.ReadWrite.All')
    }
    if ($env:AZD_ENABLE_TAP_POLICY -eq 'true') {
        $scopes.Add('Policy.ReadWrite.AuthenticationMethod')
        $scopes.Add('UserAuthenticationMethod.ReadWrite.All')
    }
    $requiredScopes = @($scopes | Select-Object -Unique)
    $authenticationInitialized = $env:AZD_GRAPH_AUTH_INITIALIZED -eq 'true'

    try {
        if ($authenticationInitialized) {
            Connect-MgGraph -TenantId $env:AZURE_TENANT_ID -NoWelcome | Out-Null
        }
        else {
            Connect-MgGraph -TenantId $env:AZURE_TENANT_ID -Scopes $requiredScopes -NoWelcome | Out-Null
        }
    }
    catch {
        throw "Unable to authenticate to Microsoft Graph with the standard cached/WAM/browser flow. $($_.Exception.Message)"
    }
    $context = Get-MgContext
    if (-not $context -or $context.TenantId -ne $env:AZURE_TENANT_ID) {
        throw "Microsoft Graph tenant context mismatch. Expected '$($env:AZURE_TENANT_ID)', received '$($context.TenantId)'."
    }
    $missingScopes = @($requiredScopes | Where-Object { $_ -notin $context.Scopes })
    if ($missingScopes.Count -gt 0 -and $authenticationInitialized) {
        Write-Warning 'The cached Microsoft Graph context is missing required scopes; requesting the complete scope set once.'
        Connect-MgGraph -TenantId $env:AZURE_TENANT_ID -Scopes $requiredScopes -NoWelcome | Out-Null
        $context = Get-MgContext
        $missingScopes = @($requiredScopes | Where-Object { $_ -notin $context.Scopes })
    }
    if ($missingScopes.Count -gt 0) {
        throw "Microsoft Graph authentication is missing required delegated scopes: $($missingScopes -join ', ')."
    }
    if (-not $authenticationInitialized) {
        Set-AzdValue AZD_GRAPH_AUTH_INITIALIZED 'true'
    }
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Path,
        [object] $Body,
        [switch] $Beta
    )

    $version = if ($Beta) { 'beta' } else { 'v1.0' }
    $parameters = @{
        Method = $Method
        Uri = "$graphRoot/$version/$($Path.TrimStart('/'))"
        ContentType = 'application/json'
    }
    if ($null -ne $Body) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    try {
        Invoke-MgGraphRequest @parameters
    }
    catch {
        $status = [int]$_.Exception.Response.StatusCode
        throw "Microsoft Graph $Method $Path failed with HTTP $status. $($_.ErrorDetails.Message)"
    }
}

function Set-AzdValue {
    param([string] $Name, [string] $Value)
    & azd env set $Name $Value | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to persist resolved object ID in $Name."
    }
    [Environment]::SetEnvironmentVariable($Name, $Value)
}

function Clear-AzdValue {
    param([Parameter(Mandatory)][string] $Name)
    & azd env set $Name '' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to clear $Name."
    }
    [Environment]::SetEnvironmentVariable($Name, $null)
}

function Assert-OwnedObjectNotReplaced {
    param(
        [Parameter(Mandatory)][string] $OwnershipName,
        [Parameter(Mandatory)][string] $CurrentId
    )

    $ownedId = [Environment]::GetEnvironmentVariable($OwnershipName)
    if ($ownedId -and $ownedId -ne $CurrentId) {
        throw "$OwnershipName records exact-owned object '$ownedId', but configuration now selects '$CurrentId'. Run the explicit tenant cleanup while the owned ID is still selected, or use a new azd environment; refusing to strand a privileged emergency object."
    }
}

function New-DiscardedPassword {
    $bytes = [byte[]]::new(48)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $random = [Convert]::ToBase64String($bytes)
    return "A9!$random"
}

function Resolve-EmergencyUser {
    param(
        [Parameter(Mandatory)]
        [ValidateSet(1, 2)]
        [int] $Number
    )

    $idName = "AZD_EMERGENCY_USER${Number}_ID"
    $upnName = "AZD_EMERGENCY_USER${Number}_UPN"
    $id = [Environment]::GetEnvironmentVariable($idName)
    $upn = [Environment]::GetEnvironmentVariable($upnName)

    if ($id) {
        Assert-OwnedObjectNotReplaced "AZD_OWNED_EMERGENCY_USER${Number}_ID" $id
        $user = Invoke-Graph GET "users/${id}?`$select=id,userPrincipalName,displayName"
        return $user
    }
    if ($upn) {
        $encodedUpn = [Uri]::EscapeDataString($upn)
        $user = Invoke-Graph GET "users/${encodedUpn}?`$select=id,userPrincipalName,displayName"
        Assert-OwnedObjectNotReplaced "AZD_OWNED_EMERGENCY_USER${Number}_ID" $user.id
        Set-AzdValue $idName $user.id
        return $user
    }

    $domain = $env:AZD_EMERGENCY_DOMAIN
    $upn = "emergency-access-$Number@$domain"
    try {
        $existing = Invoke-Graph GET "users/$([Uri]::EscapeDataString($upn))?`$select=id,userPrincipalName,displayName"
        Assert-OwnedObjectNotReplaced "AZD_OWNED_EMERGENCY_USER${Number}_ID" $existing.id
        Set-AzdValue $idName $existing.id
        Set-AzdValue $upnName $existing.userPrincipalName
        return $existing
    }
    catch {
        if ($_.Exception.Message -notmatch 'HTTP 404') {
            throw
        }
    }

    $password = New-DiscardedPassword
    try {
        $user = Invoke-Graph POST 'users' @{
            accountEnabled = $true
            displayName = "Emergency Access $Number"
            mailNickname = "emergency-access-$Number"
            userPrincipalName = $upn
            passwordProfile = @{
                forceChangePasswordNextSignIn = $true
                password = $password
            }
        }
    }
    finally {
        $password = $null
    }
    Set-AzdValue $idName $user.id
    Set-AzdValue $upnName $user.userPrincipalName
    Set-AzdValue "AZD_OWNED_EMERGENCY_USER${Number}_ID" $user.id
    Write-Host "Created $($user.userPrincipalName). Its generated initial password was intentionally discarded and cannot be recovered."
    return $user
}

function Resolve-EmergencyGroup {
    param([object[]] $Users)

    if ($env:AZD_EMERGENCY_GROUP_ID) {
        Assert-OwnedObjectNotReplaced AZD_OWNED_EMERGENCY_GROUP_ID $env:AZD_EMERGENCY_GROUP_ID
        return Invoke-Graph GET "groups/$($env:AZD_EMERGENCY_GROUP_ID)?`$select=id,displayName"
    }

    $group = Invoke-Graph POST 'groups' @{
        displayName = 'Emergency Access Accounts'
        description = 'Cloud-only emergency access accounts excluded from Conditional Access.'
        mailEnabled = $false
        mailNickname = 'emergency-access-accounts'
        securityEnabled = $true
        groupTypes = @()
    }
    Set-AzdValue AZD_EMERGENCY_GROUP_ID $group.id
    Set-AzdValue AZD_OWNED_EMERGENCY_GROUP_ID $group.id
    return $group
}

function Add-DirectoryObjectMember {
    param(
        [Parameter(Mandatory)]
        [string] $CollectionPath,
        [Parameter(Mandatory)]
        [string] $ObjectId
    )

    try {
        Invoke-Graph GET "$CollectionPath/$ObjectId" | Out-Null
        return
    }
    catch {
        if ($_.Exception.Message -notmatch 'HTTP 404') {
            throw
        }
    }

    Invoke-Graph POST "$CollectionPath/`$ref" @{
        '@odata.id' = "$graphRoot/v1.0/directoryObjects/$ObjectId"
    } | Out-Null
}

function Resolve-AdministrativeUnit {
    if ($env:AZD_USE_RESTRICTED_AU -ne 'true') {
        return $null
    }
    if ($env:AZD_ADMINISTRATIVE_UNIT_ID) {
        Assert-OwnedObjectNotReplaced AZD_OWNED_ADMINISTRATIVE_UNIT_ID $env:AZD_ADMINISTRATIVE_UNIT_ID
        return Invoke-Graph GET "directory/administrativeUnits/$($env:AZD_ADMINISTRATIVE_UNIT_ID)"
    }

    $unit = Invoke-Graph POST 'directory/administrativeUnits' @{
        displayName = 'Emergency Access'
        description = 'Restricted management administrative unit for emergency access objects.'
        isMemberManagementRestricted = $true
    }
    Set-AzdValue AZD_ADMINISTRATIVE_UNIT_ID $unit.id
    Set-AzdValue AZD_OWNED_ADMINISTRATIVE_UNIT_ID $unit.id
    return $unit
}

function Ensure-GlobalAdministrator {
    param([Parameter(Mandatory)][string] $UserId)

    $roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'
    $filter = [Uri]::EscapeDataString("principalId eq '$UserId' and roleDefinitionId eq '$roleDefinitionId' and directoryScopeId eq '/'")
    $existing = Invoke-Graph GET "roleManagement/directory/roleAssignments?`$filter=$filter"
    if (@($existing.value).Count -eq 0) {
        Invoke-Graph POST 'roleManagement/directory/roleAssignments' @{
            principalId = $UserId
            roleDefinitionId = $roleDefinitionId
            directoryScopeId = '/'
        } | Out-Null
    }
}

function Ensure-GraphAppRoles {
    param([Parameter(Mandatory)][string] $PrincipalId)

    $graph = (Invoke-Graph GET "servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id,appRoles").value |
        Select-Object -First 1
    if (-not $graph) {
        throw 'Microsoft Graph service principal was not found in this tenant.'
    }
    $existing = (Invoke-Graph GET "servicePrincipals/$PrincipalId/appRoleAssignments").value
    # Application.Read.All is required by a current Conditional Access PATCH permissions issue.
    foreach ($permission in 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'Application.Read.All') {
        $role = $graph.appRoles | Where-Object {
            $_.value -eq $permission -and 'Application' -in $_.allowedMemberTypes
        } | Select-Object -First 1
        if (-not $role) {
            throw "Microsoft Graph application role '$permission' was not found."
        }
        if ($role.id -notin @($existing.appRoleId)) {
            Invoke-Graph POST "servicePrincipals/$PrincipalId/appRoleAssignments" @{
                principalId = $PrincipalId
                resourceId = $graph.id
                appRoleId = $role.id
            } | Out-Null
        }
    }
}

function Resolve-SentinelServicePrincipal {
    if ($env:AZD_DEPLOYMENT_MODE -ne 'sentinel-function' -and
        $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -ne 'true') {
        return
    }

    $sentinelAppId = '98785600-1bb7-4fb9-b9fa-19afe2c8a360'
    $encodedFilter = [Uri]::EscapeDataString("appId eq '$sentinelAppId'")
    $principal = (Invoke-Graph GET "servicePrincipals?`$filter=$encodedFilter&`$select=id,appId,displayName").value |
        Select-Object -First 1
    if (-not $principal) {
        throw "The Azure Security Insights service principal '$sentinelAppId' was not found in this tenant."
    }
    Set-AzdValue AZD_SENTINEL_SERVICE_PRINCIPAL_ID $principal.id
}

function Ensure-FunctionAuthApplication {
    if ($env:AZD_DEPLOYMENT_MODE -ne 'sentinel-function') {
        return
    }

    $ownershipNames = @(
        'AZD_OWNED_FUNCTION_AUTH_APPLICATION_OBJECT_ID',
        'AZD_OWNED_FUNCTION_AUTH_SERVICE_PRINCIPAL_ID',
        'AZD_OWNED_FUNCTION_AUTH_CLIENT_ID',
        'AZD_OWNED_FUNCTION_AUTH_AUDIENCE',
        'AZD_OWNED_FUNCTION_AUTH_APP_ROLE_ID'
    )
    if ($env:AZD_FUNCTION_AUTH_CLIENT_ID -and
        $env:AZD_OWNED_FUNCTION_AUTH_CLIENT_ID -and
        $env:AZD_OWNED_FUNCTION_AUTH_CLIENT_ID -ne $env:AZD_FUNCTION_AUTH_CLIENT_ID) {
        throw "This environment owns Function authentication app '$($env:AZD_OWNED_FUNCTION_AUTH_CLIENT_ID)' but configuration selects '$($env:AZD_FUNCTION_AUTH_CLIENT_ID)'. Run 'azd down' before replacing the exact-owned API application, or use a new azd environment."
    }

    $application = $null
    $isOwned = $false
    if ($env:AZD_OWNED_FUNCTION_AUTH_APPLICATION_OBJECT_ID) {
        try {
            $application = Invoke-Graph GET "applications/$($env:AZD_OWNED_FUNCTION_AUTH_APPLICATION_OBJECT_ID)"
            $isOwned = $true
        }
        catch {
            if ($_.Exception.Message -notmatch 'HTTP 404') {
                throw
            }
            foreach ($name in $ownershipNames) {
                Clear-AzdValue $name
            }
        }
    }

    if (-not $application -and $env:AZD_FUNCTION_AUTH_CLIENT_ID) {
        $encodedFilter = [Uri]::EscapeDataString("appId eq '$($env:AZD_FUNCTION_AUTH_CLIENT_ID)'")
        $application = (Invoke-Graph GET "applications?`$filter=$encodedFilter").value |
            Select-Object -First 1
        if (-not $application) {
            throw "Function authentication application '$($env:AZD_FUNCTION_AUTH_CLIENT_ID)' was not found."
        }
    }

    if (-not $application) {
        $displayName = "azd-emergency-access-$($env:AZURE_ENV_NAME)"
        $application = Invoke-Graph POST 'applications' @{
            displayName = $displayName
            signInAudience = 'AzureADMyOrg'
        }
        $isOwned = $true
        Set-AzdValue AZD_OWNED_FUNCTION_AUTH_APPLICATION_OBJECT_ID $application.id
        Set-AzdValue AZD_OWNED_FUNCTION_AUTH_CLIENT_ID $application.appId
    }

    $audience = if ($env:AZD_FUNCTION_AUTH_AUDIENCE) {
        $env:AZD_FUNCTION_AUTH_AUDIENCE
    }
    else {
        "api://$($application.appId)"
    }
    $appRoles = @($application.appRoles)
    $invocationRole = $appRoles |
        Where-Object { $_.value -eq 'EmergencyAccess.Remediate' } |
        Select-Object -First 1
    if (-not $invocationRole) {
        $invocationRole = @{
            allowedMemberTypes = @('Application')
            description = 'Invoke targeted emergency access Conditional Access remediation.'
            displayName = 'Invoke emergency access remediation'
            id = [guid]::NewGuid().ToString()
            isEnabled = $true
            value = 'EmergencyAccess.Remediate'
        }
        $appRoles = @($appRoles + $invocationRole)
    }

    Invoke-Graph PATCH "applications/$($application.id)" @{
        identifierUris = @(@($application.identifierUris) + $audience | Select-Object -Unique)
        appRoles = $appRoles
        api = @{
            requestedAccessTokenVersion = 2
        }
    } | Out-Null
    Set-AzdValue AZD_FUNCTION_AUTH_CLIENT_ID $application.appId
    Set-AzdValue AZD_FUNCTION_AUTH_AUDIENCE $audience
    if ($isOwned) {
        Set-AzdValue AZD_OWNED_FUNCTION_AUTH_APPLICATION_OBJECT_ID $application.id
        Set-AzdValue AZD_OWNED_FUNCTION_AUTH_CLIENT_ID $application.appId
        Set-AzdValue AZD_OWNED_FUNCTION_AUTH_AUDIENCE $audience
        Set-AzdValue AZD_OWNED_FUNCTION_AUTH_APP_ROLE_ID ([string]$invocationRole.id)
    }

    $encodedSpFilter = [Uri]::EscapeDataString("appId eq '$($application.appId)'")
    $servicePrincipal = $null
    for ($attempt = 1; $attempt -le 6 -and -not $servicePrincipal; $attempt++) {
        $servicePrincipal = (Invoke-Graph GET "servicePrincipals?`$filter=$encodedSpFilter").value |
            Select-Object -First 1
        if (-not $servicePrincipal) {
            try {
                $servicePrincipal = Invoke-Graph POST 'servicePrincipals' @{ appId = $application.appId }
            }
            catch {
                $servicePrincipal = (Invoke-Graph GET "servicePrincipals?`$filter=$encodedSpFilter").value |
                    Select-Object -First 1
                if (-not $servicePrincipal -and $attempt -eq 6) {
                    throw
                }
            }
        }
        if (-not $servicePrincipal) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    if ($isOwned) {
        Set-AzdValue AZD_OWNED_FUNCTION_AUTH_SERVICE_PRINCIPAL_ID $servicePrincipal.id
    }
}

function Ensure-FunctionApiRoleAssignment {
    param([Parameter(Mandatory)][string] $PrincipalId)

    if ($env:AZD_DEPLOYMENT_MODE -ne 'sentinel-function') {
        return
    }

    $encodedFilter = [Uri]::EscapeDataString("appId eq '$($env:AZD_FUNCTION_AUTH_CLIENT_ID)'")
    $apiPrincipal = (Invoke-Graph GET "servicePrincipals?`$filter=$encodedFilter&`$select=id,appRoles").value |
        Select-Object -First 1
    if (-not $apiPrincipal) {
        throw 'The Function authentication service principal was not found.'
    }
    $role = $apiPrincipal.appRoles |
        Where-Object { $_.value -eq 'EmergencyAccess.Remediate' } |
        Select-Object -First 1
    if (-not $role) {
        throw "The Function API application role 'EmergencyAccess.Remediate' was not found."
    }

    $existing = (Invoke-Graph GET "servicePrincipals/$PrincipalId/appRoleAssignments").value
    if ($role.id -notin @($existing.appRoleId)) {
        Invoke-Graph POST "servicePrincipals/$PrincipalId/appRoleAssignments" @{
            principalId = $PrincipalId
            resourceId = $apiPrincipal.id
            appRoleId = $role.id
        } | Out-Null
    }
}

function Invoke-TapOnboarding {
    param([object[]] $Users, [string] $GroupId)

    $enableTap = $env:AZD_ENABLE_TAP_POLICY -eq 'true'
    if (-not $enableTap -and (Test-Interactive)) {
        $enableTap = (Read-Host 'Enable Temporary Access Pass and create reusable 2-hour TAPs? [y/N]') -match '^(y|yes)$'
    }
    if (-not $enableTap) {
        return
    }

    try {
        $currentTap = Invoke-Graph GET 'policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass' -Beta
        $target = [pscustomobject]@{
            targetType = 'group'
            id = $GroupId
            isRegistrationRequired = $false
        }
        $includeTargets = @($currentTap.includeTargets)
        if ($GroupId -notin @($includeTargets.id)) {
            $includeTargets += $target
        }
        Invoke-Graph PATCH 'policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass' @{
            '@odata.type' = '#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration'
            state = 'enabled'
            includeTargets = $includeTargets
        } -Beta | Out-Null

        if (-not (Test-Interactive)) {
            Write-Warning 'TAP policy was configured, but TAP values cannot be emitted in a noninteractive run. Create reusable two-hour TAPs manually and register at least two passkeys per emergency user.'
            return
        }

        foreach ($user in $Users) {
            $tap = Invoke-Graph POST "users/$($user.id)/authentication/temporaryAccessPassMethods" @{
                lifetimeInMinutes = 120
                isUsableOnce = $false
            } -Beta
            Write-Host "Temporary Access Pass for $($user.userPrincipalName) (shown once): $($tap.temporaryAccessPass)"
        }
        Write-Host 'Register at least two passkeys for each emergency account before considering onboarding complete.'
    }
    catch {
        Write-Warning "TAP onboarding could not be completed: $($_.Exception.Message)"
        Write-Warning 'Core provisioning remains valid. Grant the required delegated Graph consent, enable the Temporary Access Pass policy for the emergency group, create a reusable 2-hour TAP for each account, and register at least two passkeys per account.'
    }
}

Connect-ProjectGraph
if ($Phase -in 'All', 'Identities') {
    $users = @(
        Resolve-EmergencyUser 1
        Resolve-EmergencyUser 2
    )
    $group = Resolve-EmergencyGroup -Users $users
    foreach ($user in $users) {
        Add-DirectoryObjectMember "groups/$($group.id)/members" $user.id
        Ensure-GlobalAdministrator $user.id
    }

    $administrativeUnit = Resolve-AdministrativeUnit
    if ($administrativeUnit) {
        foreach ($object in @($users) + @($group)) {
            Add-DirectoryObjectMember "directory/administrativeUnits/$($administrativeUnit.id)/members" $object.id
        }
    }
    Resolve-SentinelServicePrincipal
    Ensure-FunctionAuthApplication
}

if ($Phase -in 'All', 'Workload') {
    $principalIds = @($env:AZURE_WORKLOAD_PRINCIPAL_IDS -split ',') | Where-Object { $_ }
    if ($principalIds.Count -eq 0) {
        throw 'Infrastructure did not output AZURE_WORKLOAD_PRINCIPAL_IDS.'
    }
    foreach ($principalId in $principalIds) {
        Ensure-GraphAppRoles $principalId.Trim()
    }
    if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function') {
        if (-not $env:AZURE_PLAYBOOK_PRINCIPAL_ID) {
            throw 'Infrastructure did not output AZURE_PLAYBOOK_PRINCIPAL_ID.'
        }
        Ensure-FunctionApiRoleAssignment $env:AZURE_PLAYBOOK_PRINCIPAL_ID
    }

    $users = @(
        Invoke-Graph GET "users/$($env:AZD_EMERGENCY_USER1_ID)?`$select=id,userPrincipalName"
        Invoke-Graph GET "users/$($env:AZD_EMERGENCY_USER2_ID)?`$select=id,userPrincipalName"
    )
    Invoke-TapOnboarding -Users $users -GroupId $env:AZD_EMERGENCY_GROUP_ID
}
Write-Host "Tenant bootstrap phase '$Phase' completed."
