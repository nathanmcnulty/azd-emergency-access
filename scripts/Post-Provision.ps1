[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:TeamsAuthorizationPerformed = $false

function Test-Interactive {
    return -not ($env:CI -or $env:AZD_NON_INTERACTIVE -eq 'true' -or [Console]::IsInputRedirected)
}

function Get-ArmAccessToken {
    $token = & az account get-access-token `
        --subscription $env:AZURE_SUBSCRIPTION_ID `
        --resource https://management.azure.com/ `
        --query accessToken `
        --output tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw 'Unable to acquire a cached Azure Resource Manager token for Teams connection setup.'
    }
    return $token
}

function Invoke-ArmJson {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [object] $Body
    )

    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = @{ Authorization = "Bearer $(Get-ArmAccessToken)" }
    }
    if ($null -ne $Body) {
        $parameters.Body = $Body | ConvertTo-Json -Depth 10 -Compress
        $parameters.ContentType = 'application/json'
    }
    Invoke-RestMethod @parameters
}

function Get-TeamsConnectionStatus {
    param([Parameter(Mandatory)][string] $ConnectionResourceId)

    $connection = Invoke-ArmJson `
        -Method GET `
        -Uri "https://management.azure.com$ConnectionResourceId`?api-version=2016-06-01"
    return @($connection.properties.statuses)[0].status
}

function Get-TeamsConsentLink {
    param([Parameter(Mandatory)][string] $ConnectionResourceId)

    $currentUser = Invoke-MgGraphRequest `
        -Method GET `
        -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName'
    if (-not $currentUser.id) {
        throw 'Unable to resolve the current Microsoft Graph user for Teams connection authorization.'
    }
    $body = @{
        parameters = @(
            @{
                parameterName = 'token'
                redirectUrl = 'https://portal.azure.com'
                objectId = $currentUser.id
                tenantId = $env:AZURE_TENANT_ID
            }
        )
    }
    $response = Invoke-ArmJson `
        -Method POST `
        -Uri "https://management.azure.com$ConnectionResourceId/listConsentLinks?api-version=2016-06-01" `
        -Body $body
    return @($response.value) | Select-Object -First 1
}

function Open-ConsentUrl {
    param([Parameter(Mandatory)][string] $Url)

    try {
        if ($IsWindows) {
            Start-Process $Url | Out-Null
        }
        elseif ($IsMacOS) {
            & open $Url
        }
        else {
            & xdg-open $Url
        }
    }
    catch {
        Write-Warning 'The consent page could not be opened automatically; open the printed URL manually.'
    }
}

function Complete-TeamsConnectionAuthorization {
    param([Parameter(Mandatory)][string] $ConnectionResourceId)

    $readyStatuses = @('Authenticated', 'Connected', 'Ready')
    $status = Get-TeamsConnectionStatus -ConnectionResourceId $ConnectionResourceId
    if ($status -in $readyStatuses) {
        return $true
    }

    $consent = Get-TeamsConsentLink -ConnectionResourceId $ConnectionResourceId
    if (-not $consent.link) {
        throw "The Teams connection is '$status', but Azure did not return an authorization link."
    }

    Write-Host ''
    Write-Warning 'One browser authorization is required for Teams channel notifications.'
    Write-Warning 'Sign in as the durable Teams notification account that should appear as the message sender.'
    Write-Host $consent.link
    Write-Host ''
    if (-not (Test-Interactive)) {
        Write-Warning "The Teams playbook remains disabled. Open the URL above, then rerun 'azd hooks run postprovision'."
        return $false
    }

    Open-ConsentUrl -Url $consent.link
    while ($true) {
        $response = Read-Host 'Complete the browser authorization, then press Enter to continue (or type skip)'
        if ($response.Trim() -eq 'skip') {
            return $false
        }
        $status = Get-TeamsConnectionStatus -ConnectionResourceId $ConnectionResourceId
        if ($status -in $readyStatuses) {
            $script:TeamsAuthorizationPerformed = $true
            return $true
        }
        Write-Warning "The Teams connection is still '$status'. Complete the browser authorization, then press Enter again."
    }
}

if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function') {
    foreach ($ownedOutput in @{
        AZD_OWNED_SENTINEL_ALERT_RULE_ID = $env:AZURE_SENTINEL_ALERT_RULE_ID
        AZD_OWNED_SENTINEL_AUTOMATION_RULE_ID = $env:AZURE_SENTINEL_AUTOMATION_RULE_ID
    }.GetEnumerator()) {
        if (-not $ownedOutput.Value) {
            throw "Infrastructure did not output $($ownedOutput.Key.Replace('AZD_OWNED_', 'AZURE_'))."
        }
        $existing = [Environment]::GetEnvironmentVariable($ownedOutput.Key)
        if ($existing -and $existing -ne $ownedOutput.Value) {
            throw "$($ownedOutput.Key) already records '$existing'; refusing to overwrite it with '$($ownedOutput.Value)' before exact cleanup."
        }
        & azd env set $ownedOutput.Key $ownedOutput.Value | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to persist exact Sentinel ownership record $($ownedOutput.Key)."
        }
    }
}

if ($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
    foreach ($ownedOutput in @{
        AZD_OWNED_SENTINEL_SIGNIN_RULE_ID = $env:AZURE_SENTINEL_SIGNIN_RULE_ID
        AZD_OWNED_SENTINEL_ADMIN_ACTIVITY_RULE_ID = $env:AZURE_SENTINEL_ADMIN_ACTIVITY_RULE_ID
        AZD_OWNED_SENTINEL_ACCOUNT_CHANGE_RULE_ID = $env:AZURE_SENTINEL_ACCOUNT_CHANGE_RULE_ID
        AZD_OWNED_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID = $env:AZURE_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID
        AZD_OWNED_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID = $env:AZURE_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID
    }.GetEnumerator()) {
        if (-not $ownedOutput.Value) {
            throw "Infrastructure did not output $($ownedOutput.Key.Replace('AZD_OWNED_', 'AZURE_'))."
        }
        $existing = [Environment]::GetEnvironmentVariable($ownedOutput.Key)
        if ($existing -and $existing -ne $ownedOutput.Value) {
            throw "$($ownedOutput.Key) already records '$existing'; refusing to overwrite it with '$($ownedOutput.Value)' before exact cleanup."
        }
        & azd env set $ownedOutput.Key $ownedOutput.Value | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to persist exact Sentinel ownership record $($ownedOutput.Key)."
        }
        if ($ownedOutput.Key -eq 'AZD_OWNED_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID') {
            & azd env set AZD_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID $ownedOutput.Value | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to persist the exact Sentinel Reader role-assignment record.'
            }
        }
    }
}

& "$PSScriptRoot\Bootstrap-Tenant.ps1" -Phase Workload

if ($env:AZD_DEPLOYMENT_MODE -eq 'logicapp-scheduled') {
    $workflowId = "/subscriptions/$($env:AZURE_SUBSCRIPTION_ID)/resourceGroups/$($env:AZURE_RESOURCE_GROUP)/providers/Microsoft.Logic/workflows/$($env:AZURE_WORKLOAD_RESOURCE_NAME)"
    & az resource update `
        --ids $workflowId `
        --api-version 2019-05-01 `
        --set properties.state=Enabled `
        --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Graph roles were granted, but scheduled Logic App '$($env:AZURE_WORKLOAD_RESOURCE_NAME)' could not be enabled."
    }
}

if ($env:AZD_DEPLOYMENT_MODE -eq 'sentinel-function' -or $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
    $sentinelAppId = '98785600-1bb7-4fb9-b9fa-19afe2c8a360'
    $sentinelPrincipalId = $env:AZD_SENTINEL_SERVICE_PRINCIPAL_ID
    if (-not $sentinelPrincipalId) {
        throw 'AZD_SENTINEL_SERVICE_PRINCIPAL_ID was not resolved during tenant bootstrap.'
    }
    $sentinelPrincipal = & az ad sp show `
        --id $sentinelPrincipalId `
        --query '{id:id,appId:appId}' `
        --output json `
        --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $sentinelPrincipal -or
        $sentinelPrincipal.id -ne $sentinelPrincipalId -or
        $sentinelPrincipal.appId -ne $sentinelAppId) {
        throw "The stored Sentinel service principal '$sentinelPrincipalId' does not resolve to expected application ID '$sentinelAppId'."
    }
    $playbookScope = & az group show `
        --name $env:AZURE_RESOURCE_GROUP `
        --query id `
        --output tsv

    if ($LASTEXITCODE -ne 0 -or -not $playbookScope) {
        throw "Unable to resolve playbook resource group '$($env:AZURE_RESOURCE_GROUP)' for the Sentinel role assignment."
    }
    & az role assignment create `
        --assignee-object-id $sentinelPrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role 'Microsoft Sentinel Automation Contributor' `
        --scope $playbookScope `
        --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "The Microsoft Sentinel Automation Contributor role could not be assigned to exact service principal '$sentinelPrincipalId'."
    }

}

if ($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true' -and
    $env:AZD_SENTINEL_TEAMS_DELIVERY_MODE -eq 'admin-configured') {
    $teamsConnectionId = $env:AZURE_SENTINEL_TEAMS_CONNECTION_RESOURCE_ID
    if (-not $teamsConnectionId) {
        throw 'Infrastructure did not output the Teams API connection resource ID.'
    }
    if (Complete-TeamsConnectionAuthorization -ConnectionResourceId $teamsConnectionId) {
        & az resource update `
            --ids $env:AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID `
            --api-version 2019-05-01 `
            --set properties.state=Enabled `
            --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'The Teams connection was authorized, but the Sentinel notification playbook could not be enabled.'
        }
        Write-Host 'Teams connection authorized; the Sentinel notification playbook is enabled.'
        if ($script:TeamsAuthorizationPerformed -or $env:AZD_SENTINEL_TEAMS_AUTHORIZED -ne 'true') {
            $previousSmokeTest = $env:AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY
            try {
                $env:AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY = 'true'
                & "$PSScriptRoot\Test-Deployment.ps1"
            }
            finally {
                $env:AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY = $previousSmokeTest
            }
            & azd env set AZD_SENTINEL_TEAMS_AUTHORIZED true | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw 'Teams delivery succeeded, but its validation record could not be persisted.'
            }
        }
    }
}

& azd env set AZD_PROVISIONED_MODE $env:AZD_DEPLOYMENT_MODE | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to persist the immutable provisioned deployment mode.'
}
