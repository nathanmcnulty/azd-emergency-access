#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Idempotent Microsoft Entra tenant bootstrap for emergency access (break-glass) accounts.

.DESCRIPTION
    Used by scripts/postprovision.ps1. Every "Get-OrNew*" function independently accepts an
    existing object ID; when supplied, that object is reused as-is (never modified) and only
    validated to exist. When not supplied, and only then, a new object is created. This lets a
    deployer reuse any subset of an existing emergency access user, group, or administrative unit
    while letting the template create whichever pieces are missing.

    No password is ever logged, returned, or persisted anywhere by this module: a cryptographically
    random password is generated purely as a required parameter of the user-creation Graph call and
    is discarded immediately after the call returns.
#>

Set-StrictMode -Version Latest

$script:GlobalAdministratorRoleTemplateId = '62e90394-69f5-4237-9190-012177145e10'

function New-SecureRandomPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically random password for one-time use in a user-creation call.
        The caller must not log, persist, or return this value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int] $Length = 32
    )

    $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*-_=+'
    $bytes = [byte[]]::new($Length)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $password = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    return $password
}

function Get-OrNewEmergencyAccessUser {
    <#
    .SYNOPSIS
        Reuses an existing emergency access user (by ID or UPN) or creates a new cloud-only user.

    .PARAMETER ExistingUserId
        Object ID of an existing user to reuse. Takes precedence over ExistingUserUpn.

    .PARAMETER ExistingUserUpn
        User principal name of an existing user to reuse.

    .PARAMETER NewUserPrefix
        Prefix used to build the UPN/display name when a new user must be created, for example
        'emergency-access-1'.

    .PARAMETER Domain
        Verified domain used to build the new user's UPN (e.g. contoso.onmicrosoft.com).

    .OUTPUTS
        [pscustomobject] with Id, UserPrincipalName, Created ($true/$false). Never includes a
        password.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string] $ExistingUserId,

        [Parameter(Mandatory = $false)]
        [string] $ExistingUserUpn,

        [Parameter(Mandatory = $true)]
        [string] $NewUserPrefix,

        [Parameter(Mandatory = $true)]
        [string] $Domain
    )

    if (-not [string]::IsNullOrWhiteSpace($ExistingUserId)) {
        $user = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$ExistingUserId`?`$select=id,userPrincipalName"
        return [pscustomobject]@{ Id = $user.id; UserPrincipalName = $user.userPrincipalName; Created = $false }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExistingUserUpn)) {
        $user = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$ExistingUserUpn`?`$select=id,userPrincipalName"
        return [pscustomobject]@{ Id = $user.id; UserPrincipalName = $user.userPrincipalName; Created = $false }
    }

    $upn = "$NewUserPrefix@$Domain"

    $existing = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users?`$filter=userPrincipalName eq '$upn'&`$select=id,userPrincipalName"
    if (@($existing.value).Count -gt 0) {
        $user = $existing.value[0]
        return [pscustomobject]@{ Id = $user.id; UserPrincipalName = $user.userPrincipalName; Created = $false }
    }

    # Generated only for this single creation call; never logged, returned, or persisted.
    $password = New-SecureRandomPassword
    try {
        $body = @{
            accountEnabled    = $true
            displayName       = $NewUserPrefix
            mailNickname      = ($NewUserPrefix -replace '[^a-zA-Z0-9]', '')
            userPrincipalName = $upn
            passwordProfile   = @{
                password                      = $password
                forceChangePasswordNextSignIn = $false
            }
            passwordPolicies  = 'DisablePasswordExpiration'
        }

        $created = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/users' `
            -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json'
    }
    finally {
        if ($body -and $body.passwordProfile) {
            $body.passwordProfile.password = $null
        }
        $password = $null
        Remove-Variable -Name password -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{ Id = $created.id; UserPrincipalName = $created.userPrincipalName; Created = $true }
}

function Get-OrNewEmergencyAccessGroup {
    <#
    .SYNOPSIS
        Reuses an existing emergency access security group or creates a new one.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string] $ExistingGroupId,

        [Parameter(Mandatory = $true)]
        [string] $GroupDisplayName,

        [Parameter(Mandatory = $true)]
        [string[]] $MemberUserIds
    )

    if (-not [string]::IsNullOrWhiteSpace($ExistingGroupId)) {
        $group = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$ExistingGroupId`?`$select=id,displayName"
        Add-MissingGroupMembers -GroupId $group.id -MemberUserIds $MemberUserIds
        return [pscustomobject]@{ Id = $group.id; DisplayName = $group.displayName; Created = $false }
    }

    $existing = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$GroupDisplayName'&`$select=id,displayName"
    if (@($existing.value).Count -gt 0) {
        $group = $existing.value[0]
        Add-MissingGroupMembers -GroupId $group.id -MemberUserIds $MemberUserIds
        return [pscustomobject]@{ Id = $group.id; DisplayName = $group.displayName; Created = $false }
    }

    $body = @{
        displayName     = $GroupDisplayName
        mailEnabled     = $false
        mailNickname    = ($GroupDisplayName -replace '[^a-zA-Z0-9]', '')
        securityEnabled = $true
        'members@odata.bind' = @($MemberUserIds | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$_" })
    }

    $created = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' `
        -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json'

    return [pscustomobject]@{ Id = $created.id; DisplayName = $created.displayName; Created = $true }
}

function Add-MissingGroupMembers {
    <#
    .SYNOPSIS
        Adds any of the given user IDs that are not already members of the group.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $GroupId,

        [Parameter(Mandatory = $true)]
        [string[]] $MemberUserIds
    )

    $currentMembers = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members?`$select=id").value
    $currentIds = @($currentMembers | ForEach-Object { $_.id })

    foreach ($userId in $MemberUserIds) {
        if ($currentIds -notcontains $userId) {
            $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$userId" }
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$GroupId/members/`$ref" `
                -Body ($body | ConvertTo-Json) -ContentType 'application/json' | Out-Null
        }
    }
}

function Get-OrNewRestrictedManagementAdministrativeUnit {
    <#
    .SYNOPSIS
        Reuses an existing restricted management administrative unit or creates a new one
        containing the emergency access users and group.

    .DESCRIPTION
        A restricted management administrative unit (isMemberManagementRestricted = $true)
        protects the emergency access user and group objects from being read or modified by
        administrators who are not explicitly scoped to the AU, even if they hold a broad
        directory role elsewhere. It does NOT scope the Global Administrator role assignment
        itself -- Global Administrator is always a tenant-wide role; see Grant-GlobalAdministratorRole.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string] $ExistingAdministrativeUnitId,

        [Parameter(Mandatory = $true)]
        [string] $DisplayName,

        [Parameter(Mandatory = $true)]
        [string[]] $MemberObjectIds
    )

    if (-not [string]::IsNullOrWhiteSpace($ExistingAdministrativeUnitId)) {
        $au = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$ExistingAdministrativeUnitId`?`$select=id,displayName"
        Add-MissingAdministrativeUnitMembers -AdministrativeUnitId $au.id -MemberObjectIds $MemberObjectIds
        return [pscustomobject]@{ Id = $au.id; DisplayName = $au.displayName; Created = $false }
    }

    $existing = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits?`$filter=displayName eq '$DisplayName'&`$select=id,displayName"
    if (@($existing.value).Count -gt 0) {
        $au = $existing.value[0]
        Add-MissingAdministrativeUnitMembers -AdministrativeUnitId $au.id -MemberObjectIds $MemberObjectIds
        return [pscustomobject]@{ Id = $au.id; DisplayName = $au.displayName; Created = $false }
    }

    $body = @{
        displayName                     = $DisplayName
        description                     = 'Restricted management administrative unit protecting emergency access (break-glass) accounts. Created by azd-emergency-access.'
        isMemberManagementRestricted    = $true
    }

    $created = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/directory/administrativeUnits' `
        -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json'

    Add-MissingAdministrativeUnitMembers -AdministrativeUnitId $created.id -MemberObjectIds $MemberObjectIds
    return [pscustomobject]@{ Id = $created.id; DisplayName = $created.displayName; Created = $true }
}

function Add-MissingAdministrativeUnitMembers {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $AdministrativeUnitId,

        [Parameter(Mandatory = $true)]
        [string[]] $MemberObjectIds
    )

    $currentMembers = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$AdministrativeUnitId/members?`$select=id").value
    $currentIds = @($currentMembers | ForEach-Object { $_.id })

    foreach ($objectId in $MemberObjectIds) {
        if ($currentIds -notcontains $objectId) {
            $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$objectId" }
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/directory/administrativeUnits/$AdministrativeUnitId/members/`$ref" `
                -Body ($body | ConvertTo-Json) -ContentType 'application/json' | Out-Null
        }
    }
}

function Grant-GlobalAdministratorRole {
    <#
    .SYNOPSIS
        Idempotently assigns the tenant-wide Global Administrator directory role to a user.

    .DESCRIPTION
        Emergency access accounts must always hold a permanent, tenant-wide Global Administrator
        assignment -- never an administrative-unit-scoped role assignment, which would defeat the
        purpose of a break-glass account during a tenant-wide lockout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $UserId
    )

    $role = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/directoryRoles(roleTemplateId='$script:GlobalAdministratorRoleTemplateId')" `
        -SkipHttpErrorCheck

    if ($role.error) {
        # Role not yet activated in this tenant; activate it from its template.
        $activateBody = @{ roleTemplateId = $script:GlobalAdministratorRoleTemplateId }
        $role = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/directoryRoles' `
            -Body ($activateBody | ConvertTo-Json) -ContentType 'application/json'
    }

    $currentMembers = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/directoryRoles/$($role.id)/members?`$select=id").value
    $currentIds = @($currentMembers | ForEach-Object { $_.id })

    if ($currentIds -notcontains $UserId) {
        $body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$UserId" }
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/directoryRoles/$($role.id)/members/`$ref" `
            -Body ($body | ConvertTo-Json) -ContentType 'application/json' | Out-Null
    }
}

Export-ModuleMember -Function @(
    'New-SecureRandomPassword',
    'Get-OrNewEmergencyAccessUser',
    'Get-OrNewEmergencyAccessGroup',
    'Add-MissingGroupMembers',
    'Get-OrNewRestrictedManagementAdministrativeUnit',
    'Add-MissingAdministrativeUnitMembers',
    'Grant-GlobalAdministratorRole'
)
