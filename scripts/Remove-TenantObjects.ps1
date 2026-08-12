[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [switch] $DeleteObjectsCreatedByThisEnvironment
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Cleanup.Guards.psm1" -Force
Import-Module "$PSScriptRoot\Tenant.Guards.psm1" -Force
Assert-AzdTenantContext
if (-not $DeleteObjectsCreatedByThisEnvironment) {
    throw 'Use -DeleteObjectsCreatedByThisEnvironment to acknowledge tenant-object deletion.'
}

$token = & az account get-access-token --subscription $env:AZURE_SUBSCRIPTION_ID `
    --tenant $env:AZURE_TENANT_ID --resource-type ms-graph --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) {
    throw 'Unable to acquire a Microsoft Graph token.'
}
$headers = @{ Authorization = "Bearer $token" }

$objects = @(
    @{
        Ownership = 'AZD_OWNED_ADMINISTRATIVE_UNIT_ID'
        CurrentName = 'AZD_ADMINISTRATIVE_UNIT_ID'
        CurrentId = $env:AZD_ADMINISTRATIVE_UNIT_ID
        OwnedId = $env:AZD_OWNED_ADMINISTRATIVE_UNIT_ID
        Uri = 'https://graph.microsoft.com/v1.0/directory/administrativeUnits'
    },
    @{
        Ownership = 'AZD_OWNED_EMERGENCY_GROUP_ID'
        CurrentName = 'AZD_EMERGENCY_GROUP_ID'
        CurrentId = $env:AZD_EMERGENCY_GROUP_ID
        OwnedId = $env:AZD_OWNED_EMERGENCY_GROUP_ID
        Uri = 'https://graph.microsoft.com/v1.0/groups'
    },
    @{
        Ownership = 'AZD_OWNED_EMERGENCY_USER1_ID'
        CurrentName = 'AZD_EMERGENCY_USER1_ID'
        UpnName = 'AZD_EMERGENCY_USER1_UPN'
        CurrentId = $env:AZD_EMERGENCY_USER1_ID
        OwnedId = $env:AZD_OWNED_EMERGENCY_USER1_ID
        Uri = 'https://graph.microsoft.com/v1.0/users'
    },
    @{
        Ownership = 'AZD_OWNED_EMERGENCY_USER2_ID'
        CurrentName = 'AZD_EMERGENCY_USER2_ID'
        UpnName = 'AZD_EMERGENCY_USER2_UPN'
        CurrentId = $env:AZD_EMERGENCY_USER2_ID
        OwnedId = $env:AZD_OWNED_EMERGENCY_USER2_ID
        Uri = 'https://graph.microsoft.com/v1.0/users'
    }
)

foreach ($object in $objects) {
    if (Test-OwnedObjectId -CurrentId $object.CurrentId -OwnedId $object.OwnedId) {
        if ($PSCmdlet.ShouldProcess($object.OwnedId, "Delete object recorded by $($object.Ownership)")) {
            Invoke-RestMethod -Method DELETE -Uri "$($object.Uri)/$($object.OwnedId)" -Headers $headers
            & azd env set $object.Ownership '' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to clear $($object.Ownership)." }
            & azd env set $object.CurrentName '' | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Unable to clear $($object.CurrentName)." }
            if ($object.UpnName) {
                & azd env set $object.UpnName '' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Unable to clear $($object.UpnName)." }
            }
        }
    }
    elseif ($object.OwnedId) {
        Write-Warning "Skipped $($object.Ownership): its exact owned ID does not match the current configured object ID."
    }
}

$token = $null
