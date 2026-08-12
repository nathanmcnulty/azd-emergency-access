#Requires -Version 7.0

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [switch] $DeleteTenantObjects
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $DeleteTenantObjects) {
    throw 'Pass -DeleteTenantObjects to acknowledge permanent deletion of template-created tenant objects.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\shared\PreprovisionSupport.psm1') -Force

function Remove-OwnedGraphObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $CurrentIdVariable,
        [Parameter(Mandatory)] [string] $CreatedIdVariable,
        [Parameter(Mandatory)] [string] $RelativeUri,
        [Parameter(Mandatory)] [string[]] $LiveVariables
    )

    $currentId = Get-EnvValue -Name $CurrentIdVariable
    $createdId = Get-EnvValue -Name $CreatedIdVariable
    if ([string]::IsNullOrWhiteSpace($createdId) -or $createdId -ne $currentId) {
        Write-Host "Skipping ${Label}: the current object ID is not recorded as created by this azd environment."
        return
    }

    if ($PSCmdlet.ShouldProcess("$Label $currentId", 'Permanently delete Microsoft Entra object')) {
        Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/$RelativeUri/$currentId"
        Set-EnvValue -Name $CreatedIdVariable -Value ''
        foreach ($variableName in $LiveVariables) {
            Set-EnvValue -Name $variableName -Value ''
        }
        Write-Host "Deleted $Label $currentId." -ForegroundColor Green
    }
}

Connect-MgGraph -NoWelcome -Scopes @(
    'User.ReadWrite.All',
    'Group.ReadWrite.All',
    'AdministrativeUnit.ReadWrite.All',
    'Application.ReadWrite.All'
) | Out-Null

try {
    Remove-OwnedGraphObject -Label 'restricted administrative unit' -CurrentIdVariable 'EMERGENCY_ACCESS_AU_ID' -CreatedIdVariable 'AZD_CREATED_AU_ID' -RelativeUri 'directory/administrativeUnits' -LiveVariables @('EMERGENCY_ACCESS_AU_ID')
    Remove-OwnedGraphObject -Label 'emergency access group' -CurrentIdVariable 'EMERGENCY_ACCESS_GROUP_ID' -CreatedIdVariable 'AZD_CREATED_GROUP_ID' -RelativeUri 'groups' -LiveVariables @('EMERGENCY_ACCESS_GROUP_ID')
    Remove-OwnedGraphObject -Label 'emergency access user 1' -CurrentIdVariable 'EMERGENCY_ACCESS_USER1_ID' -CreatedIdVariable 'AZD_CREATED_USER1_ID' -RelativeUri 'users' -LiveVariables @('EMERGENCY_ACCESS_USER1_ID', 'EMERGENCY_ACCESS_USER1_UPN')
    Remove-OwnedGraphObject -Label 'emergency access user 2' -CurrentIdVariable 'EMERGENCY_ACCESS_USER2_ID' -CreatedIdVariable 'AZD_CREATED_USER2_ID' -RelativeUri 'users' -LiveVariables @('EMERGENCY_ACCESS_USER2_ID', 'EMERGENCY_ACCESS_USER2_UPN')
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

$appObjectId = Get-EnvValue -Name 'FUNCTION_AAD_APP_OBJECT_ID'
$createdAppObjectId = Get-EnvValue -Name 'AZD_CREATED_FUNCTION_AAD_APP_OBJECT_ID'
if (-not [string]::IsNullOrWhiteSpace($createdAppObjectId) -and $createdAppObjectId -eq $appObjectId) {
    if ($PSCmdlet.ShouldProcess("Entra application $appObjectId", 'Permanently delete application registration')) {
        & az ad app delete --id $appObjectId
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete Entra application $appObjectId."
        }
        Set-EnvValue -Name 'AZD_CREATED_FUNCTION_AAD_APP_OBJECT_ID' -Value ''
        Set-EnvValue -Name 'FUNCTION_AAD_APP_OBJECT_ID' -Value ''
        Set-EnvValue -Name 'FUNCTION_AAD_CLIENT_ID' -Value ''
        Write-Host "Deleted Entra application $appObjectId." -ForegroundColor Green
    }
}
else {
    Write-Host 'Skipping Function authentication application: the current object ID is not recorded as created by this azd environment.'
}
