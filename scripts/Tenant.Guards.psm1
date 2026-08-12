function Assert-TenantMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedTenantId,
        [Parameter(Mandatory)][string] $SubscriptionTenantId,
        [Parameter(Mandatory)][string] $ActiveTenantId
    )

    foreach ($id in @($ExpectedTenantId, $SubscriptionTenantId, $ActiveTenantId)) {
        $parsed = [guid]::Empty
        if (-not [guid]::TryParse($id, [ref]$parsed)) {
            throw 'Tenant context values must all be valid tenant GUIDs.'
        }
    }
    if ($ExpectedTenantId -ne $SubscriptionTenantId -or $ExpectedTenantId -ne $ActiveTenantId) {
        throw "Tenant context mismatch. The azd environment expects tenant '$ExpectedTenantId', the subscription belongs to '$SubscriptionTenantId', and Azure CLI is active in '$ActiveTenantId'. Select the correct tenant before any Microsoft Graph mutation."
    }
}

function Assert-AzdTenantContext {
    [CmdletBinding()]
    param()

    if (-not $env:AZURE_SUBSCRIPTION_ID -or -not $env:AZURE_TENANT_ID) {
        throw 'AZURE_SUBSCRIPTION_ID and AZURE_TENANT_ID are required before Microsoft Graph operations.'
    }
    $subscriptionTenant = & az account show --subscription $env:AZURE_SUBSCRIPTION_ID --query tenantId -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $subscriptionTenant) {
        throw "Unable to resolve the tenant for subscription '$($env:AZURE_SUBSCRIPTION_ID)'."
    }
    $activeTenant = & az account show --query tenantId -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $activeTenant) {
        throw 'Unable to resolve the active Azure CLI tenant.'
    }
    Assert-TenantMatch -ExpectedTenantId $env:AZURE_TENANT_ID `
        -SubscriptionTenantId $subscriptionTenant.Trim() -ActiveTenantId $activeTenant.Trim()
}

Export-ModuleMember -Function Assert-TenantMatch, Assert-AzdTenantContext
