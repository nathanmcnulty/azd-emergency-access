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
    $subscriptionJson = & az account show --subscription $env:AZURE_SUBSCRIPTION_ID `
        --query '{id:id,tenantId:tenantId}' --output json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $subscriptionJson) {
        throw "Unable to resolve the tenant for subscription '$($env:AZURE_SUBSCRIPTION_ID)'."
    }
    $subscription = $subscriptionJson | ConvertFrom-Json
    $activeJson = & az account show --query '{id:id,tenantId:tenantId}' --output json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $activeJson) {
        throw 'Unable to resolve the active Azure CLI tenant.'
    }
    $active = $activeJson | ConvertFrom-Json
    Assert-TenantMatch -ExpectedTenantId $env:AZURE_TENANT_ID `
        -SubscriptionTenantId ([string] $subscription.tenantId) -ActiveTenantId ([string] $active.tenantId)
    if ([string] $active.id -ne [string] $env:AZURE_SUBSCRIPTION_ID) {
        throw "Azure subscription mismatch. The azd environment expects '$($env:AZURE_SUBSCRIPTION_ID)' but Azure CLI is active in '$($active.id)'."
    }
}

function Get-AzdEnvironmentValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Name)

    $processValue = [Environment]::GetEnvironmentVariable($Name)
    if ($null -ne $processValue -and $processValue -ne '') { return $processValue }
    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) { return $null }
    $value = & azd env get-value $Name 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $value = ($value -join "`n").Trim()
    if ($value) {
        [Environment]::SetEnvironmentVariable($Name, $value, 'Process')
        return $value
    }
    return $null
}

Export-ModuleMember -Function Assert-TenantMatch, Assert-AzdTenantContext, Get-AzdEnvironmentValue
