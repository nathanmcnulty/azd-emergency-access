<#
.SYNOPSIS
    Shared helpers for scripts/preprovision.ps1: azd environment persistence, interactive/
    non-interactive detection, and the sentinel-function Entra app registration bootstrap.

.DESCRIPTION
    Kept in src/shared alongside the remediation module so both preprovision and postprovision
    share a single, testable implementation of "how do we read/write azd environment values" and
    "are we running interactively".
#>

Set-StrictMode -Version Latest

function Test-InteractiveSession {
    <#
    .SYNOPSIS
        Determines whether the current session can prompt a human for input.

    .DESCRIPTION
        Returns $false when running under common CI systems, when stdin is redirected (piped or
        non-console), or when azd's own non-interactive signal is present. Returns $true
        otherwise. Used to decide between interactive prompts and strict non-interactive failures
        with explicit remediation instructions.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($env:CI -eq 'true' -or $env:TF_BUILD -or $env:GITHUB_ACTIONS -eq 'true' -or $env:AZD_IN_CI -eq 'true' -or $env:AZD_NON_INTERACTIVE -eq 'true') {
        return $false
    }

    try {
        if ([Console]::IsInputRedirected) {
            return $false
        }
    }
    catch {
        return $false
    }

    if ([Environment]::UserInteractive -eq $false) {
        return $false
    }

    return $true
}

function Get-EnvValue {
    <#
    .SYNOPSIS
        Reads an azd environment variable from the current process environment.

    .DESCRIPTION
        azd injects every value from the active environment's .env file into the process
        environment before running hooks, so a plain environment variable read is sufficient and
        avoids an extra `azd env get-values` invocation per lookup.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    return [Environment]::GetEnvironmentVariable($Name)
}

function Set-EnvValue {
    <#
    .SYNOPSIS
        Persists an azd environment variable via `azd env set` and mirrors it into the current
        process environment so subsequent logic in the same script observes the new value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    [Environment]::SetEnvironmentVariable($Name, $Value)

    if (Get-Command -Name 'azd' -ErrorAction SilentlyContinue) {
        & azd env set $Name $Value | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "azd env set $Name failed with exit code $LASTEXITCODE. The value is set for this process but was not persisted."
        }
    }
    else {
        Write-Warning "azd CLI not found on PATH; '$Name' was not persisted to the azd environment."
    }
}

function Set-EnvValueIfMissing {
    <#
    .SYNOPSIS
        Persists a default value only when the named environment variable is not already set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    $current = Get-EnvValue -Name $Name
    if ($null -eq $current) {
        Set-EnvValue -Name $Name -Value $Value
    }
}

function Get-RequiredEnvValue {
    <#
    .SYNOPSIS
        Returns an environment value, prompting interactively or failing with a precise
        remediation instruction when it is required but missing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Prompt,

        [Parameter(Mandatory = $true)]
        [bool] $IsInteractive
    )

    $value = Get-EnvValue -Name $Name
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        return $value
    }

    if ($IsInteractive) {
        $value = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "$Name is required and no value was provided."
        }
        Set-EnvValue -Name $Name -Value $value
        return $value
    }

    throw "$Name is required and no value was found. Set it before provisioning non-interactively, for example: azd env set $Name <value>."
}

function Test-SentinelWorkspace {
    <#
    .SYNOPSIS
        Best-effort validation that the referenced Log Analytics workspace exists. Never fails
        provisioning solely because the check itself could not run (for example, insufficient
        `az` permissions to read across subscriptions) -- it only fails when the workspace is
        confirmed absent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $WorkspaceName,

        [Parameter(Mandatory = $true)]
        [string] $ResourceGroup,

        [Parameter(Mandatory = $true)]
        [string] $SubscriptionId
    )

    if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
        Write-Warning 'Azure CLI not found on PATH; skipping existence check for the Sentinel workspace. Deployment will fail later if it does not exist.'
        return
    }

    $azArgs = @(
        'monitor', 'log-analytics', 'workspace', 'show',
        '--workspace-name', $WorkspaceName,
        '--resource-group', $ResourceGroup,
        '--subscription', $SubscriptionId,
        '-o', 'none'
    )

    & az @azArgs 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not find Log Analytics workspace '$WorkspaceName' in resource group '$ResourceGroup' (subscription '$SubscriptionId'). sentinel-function mode requires an existing Sentinel-enabled workspace. Verify SENTINEL_WORKSPACE_NAME, SENTINEL_WORKSPACE_RESOURCE_GROUP, and SENTINEL_WORKSPACE_SUBSCRIPTION_ID, and that Microsoft Sentinel is enabled on that workspace."
    }

    Write-Host "Confirmed Log Analytics workspace '$WorkspaceName' exists." -ForegroundColor Green

    $onboardingUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/providers/Microsoft.SecurityInsights/onboardingStates/default?api-version=2024-03-01"
    & az rest --method get --uri $onboardingUri --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Log Analytics workspace '$WorkspaceName' exists, but Microsoft Sentinel onboarding state 'default' was not found. Enable Microsoft Sentinel on the workspace before using sentinel-function mode."
    }

    Write-Host "Confirmed Microsoft Sentinel is enabled on '$WorkspaceName'." -ForegroundColor Green
}

function Initialize-FunctionAadApplication {
    <#
    .SYNOPSIS
        Idempotently creates (or reuses) the Entra ID application registration used as the Easy
        Auth V2 resource for the sentinel-function mode's protected HTTP trigger.

    .DESCRIPTION
        No client secret or certificate is created -- this application registration exists only
        to give the Function App a stable Application ID URI (api://<appId>) for token audience
        validation. The Sentinel playbook calls the function using its own managed identity, not
        this application, so no credential of any kind is required here.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $DisplayName
    )

    if (-not (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI (az) is required to create the Entra application registration for sentinel-function mode.'
    }

    $existingJson = & az ad app list --display-name $DisplayName -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query existing Entra application registrations for '$DisplayName'. Ensure you are signed in with 'az login' and hold at least Application.ReadWrite.All (or Cloud Application Administrator)."
    }

    $existing = @($existingJson | ConvertFrom-Json)
    $app = $existing | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1

    $created = $false
    if (-not $app) {
        Write-Host "Creating Entra application registration '$DisplayName'..."
        $createdJson = & az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg -o json 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create Entra application registration '$DisplayName'. Ensure you hold at least Application.ReadWrite.All (or Cloud Application Administrator)."
        }
        $app = $createdJson | ConvertFrom-Json
        $created = $true
    }
    else {
        Write-Host "Reusing existing Entra application registration '$DisplayName' (appId $($app.appId))."
    }

    $expectedIdentifierUri = "api://$($app.appId)"
    $hasIdentifierUri = @($app.identifierUris) -contains $expectedIdentifierUri
    if (-not $hasIdentifierUri) {
        Write-Host "Setting Application ID URI '$expectedIdentifierUri'..."
        & az ad app update --id $app.appId --identifier-uris $expectedIdentifierUri -o none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set the Application ID URI on '$DisplayName'. Ensure you hold at least Application.ReadWrite.All (or Cloud Application Administrator)."
        }
    }

    $servicePrincipalId = & az ad sp list --filter "appId eq '$($app.appId)'" --query '[0].id' --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query the service principal for Entra application '$DisplayName'."
    }
    if ([string]::IsNullOrWhiteSpace($servicePrincipalId)) {
        & az ad sp create --id $app.appId --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create the service principal for Entra application '$DisplayName'."
        }
    }

    return [pscustomobject]@{
        AppId    = $app.appId
        ObjectId = $app.id
        Created  = $created
    }
}

Export-ModuleMember -Function @(
    'Test-InteractiveSession',
    'Get-EnvValue',
    'Set-EnvValue',
    'Set-EnvValueIfMissing',
    'Get-RequiredEnvValue',
    'Test-SentinelWorkspace',
    'Initialize-FunctionAadApplication'
)
