<#
.SYNOPSIS
    Entra-protected HTTP-triggered Azure Function for AZD_DEPLOYMENT_MODE = sentinel-function.

.DESCRIPTION
    Invoked by the Sentinel alert-triggered Logic App playbook, authenticated with the playbook's
    system-assigned managed identity. Remediates exactly the single Conditional Access policy
    identified by the CAPolicyId supplied in the request body (extracted by the playbook from the
    Sentinel NRT alert's custom details), preserving any existing exclusions.

    function.json declares authLevel "anonymous" intentionally: this function does not use
    Functions host keys or anonymous public access. Authentication and authorization are enforced
    at the platform level by Azure App Service Authentication (Easy Auth V2 / authsettingsV2),
    which is configured by infra/modules/function.bicep and scripts/postprovision.ps1 to require
    an Entra ID token and to allow only the Sentinel playbook Logic App's managed identity
    (allowedPrincipals.identities). Any request that is not already authenticated by the platform
    never reaches this script -- see README.md "Security" section.

.NOTES
    Authenticates to Microsoft Graph using the function app's user-assigned managed identity.
    Required Microsoft Graph application permissions: Policy.Read.All,
    Policy.ReadWrite.ConditionalAccess.
#>
param(
    [Parameter(Mandatory = $true)]
    $Request,

    [Parameter(Mandatory = $false)]
    $TriggerMetadata
)

$ErrorActionPreference = 'Stop'

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
if (-not (Get-Command -Name 'Invoke-EmergencyAccessRemediation' -ErrorAction SilentlyContinue)) {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\EmergencyAccessRemediation\EmergencyAccessRemediation.psm1') -Force
}

function New-HttpResponse {
    param([int] $StatusCode, [hashtable] $Body)

    Push-OutputBinding -Name Response -Value @{
        StatusCode = $StatusCode
        Body       = ($Body | ConvertTo-Json -Depth 6)
        Headers    = @{ 'Content-Type' = 'application/json' }
    }
}

$groupId = $env:EMERGENCY_ACCESS_GROUP_ID
$clientId = $env:REMEDIATION_MANAGED_IDENTITY_CLIENT_ID

$caPolicyId = $null
if ($Request.Body) {
    if ($Request.Body -is [string]) {
        try { $caPolicyId = ($Request.Body | ConvertFrom-Json).CAPolicyId } catch { $caPolicyId = $null }
    }
    else {
        $caPolicyId = $Request.Body.CAPolicyId
    }
}

if ([string]::IsNullOrWhiteSpace($caPolicyId)) {
    New-HttpResponse -StatusCode 400 -Body @{ error = 'Request body must include a non-empty CAPolicyId property.' }
    return
}

try {
    if (-not (Get-MgContext)) {
        if ($clientId) {
            Connect-MgGraph -Identity -ClientId $clientId -NoWelcome
        }
        else {
            Connect-MgGraph -Identity -NoWelcome
        }
    }

    $result = Invoke-EmergencyAccessRemediation -EmergencyAccessGroupObjectId $groupId -CAPolicyId $caPolicyId

    $statusCode = if ($result.succeeded) { 200 } else { 500 }
    New-HttpResponse -StatusCode $statusCode -Body $result
}
catch {
    Write-Error $_.Exception.Message
    New-HttpResponse -StatusCode 500 -Body @{ error = $_.Exception.Message; caPolicyId = $caPolicyId }
}
