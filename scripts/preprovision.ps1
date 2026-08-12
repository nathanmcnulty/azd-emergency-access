#Requires -Version 7.0
<#
.SYNOPSIS
    azd preprovision hook for azd-emergency-access.

.DESCRIPTION
    Runs before `azd provision`. Performs strict validation of AZD_DEPLOYMENT_MODE and every
    mode-specific environment variable, applying and persisting sane defaults so the template
    works identically whether azd is run interactively (a human answering prompts) or
    non-interactively (CI/CD, `azd up --no-prompt`, or any pipe/redirected session).

    Responsibilities:
      - Require exactly one AZD_DEPLOYMENT_MODE value; prompt (interactive) or fail with an exact
        remediation command (non-interactive).
      - Persist defaults for every mode-specific setting via `azd env set` so re-running
        provisioning is idempotent and reproducible.
      - For sentinel-function mode: validate the existing Sentinel workspace parameters are
        present, and idempotently create (or reuse) the Entra ID application registration used to
        protect the Function App's HTTP trigger with Easy Auth V2. This must happen here, before
        `azd provision`, because infra/main.bicep consumes FUNCTION_AAD_CLIENT_ID as an input.

    This script never provisions Azure resources itself (that is infra/main.bicep's job) and never
    performs the tenant bootstrap (that is scripts/postprovision.ps1's job, which runs after
    resources exist).
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\shared\PreprovisionSupport.psm1') -Force

Write-Host '=== azd-emergency-access: preprovision ===' -ForegroundColor Cyan

$isInteractive = Test-InteractiveSession
Write-Host "Session mode: $(if ($isInteractive) { 'interactive' } else { 'non-interactive' })"

# ---------------------------------------------------------------------------
# 1. AZD_DEPLOYMENT_MODE (exactly one required)
# ---------------------------------------------------------------------------
$allowedModes = @('automation-scheduled', 'function-scheduled', 'logicapp-scheduled', 'sentinel-function')

$deploymentMode = Get-EnvValue -Name 'AZD_DEPLOYMENT_MODE'

if ([string]::IsNullOrWhiteSpace($deploymentMode)) {
    if ($isInteractive) {
        Write-Host ''
        Write-Host 'Select a deployment mode (exactly one is deployed per environment):'
        for ($i = 0; $i -lt $allowedModes.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f ($i + 1), $allowedModes[$i])
        }
        $selection = $null
        while (-not $selection) {
            $answer = Read-Host 'Enter the number of the mode to deploy'
            if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $allowedModes.Count) {
                $selection = $allowedModes[[int]$answer - 1]
            }
            else {
                Write-Host 'Invalid selection. Enter a number from the list above.' -ForegroundColor Yellow
            }
        }
        $deploymentMode = $selection
    }
    else {
        throw "AZD_DEPLOYMENT_MODE is required and no value was found. Set it before provisioning non-interactively, for example: azd env set AZD_DEPLOYMENT_MODE function-scheduled. Allowed values: $($allowedModes -join ', ')."
    }
}

if ($deploymentMode -notin $allowedModes) {
    throw "AZD_DEPLOYMENT_MODE value '$deploymentMode' is not valid. Allowed values: $($allowedModes -join ', ')."
}

Set-EnvValue -Name 'AZD_DEPLOYMENT_MODE' -Value $deploymentMode
Write-Host "AZD_DEPLOYMENT_MODE = $deploymentMode" -ForegroundColor Green

$lockedMode = Get-EnvValue -Name 'AZD_DEPLOYMENT_MODE_LOCK'
if ([string]::IsNullOrWhiteSpace($lockedMode)) {
    Set-EnvValue -Name 'AZD_DEPLOYMENT_MODE_LOCK' -Value $deploymentMode
}
elseif ($lockedMode -ne $deploymentMode) {
    throw "This azd environment is locked to deployment mode '$lockedMode'. Changing AZD_DEPLOYMENT_MODE in place can leave multiple remediators or external Sentinel rules active. Create a separate azd environment for '$deploymentMode', or run 'azd down --purge' in this environment before recreating it."
}

# ---------------------------------------------------------------------------
# 2. Location default and soft policy guidance
# ---------------------------------------------------------------------------
$location = Get-EnvValue -Name 'AZURE_LOCATION'
if ([string]::IsNullOrWhiteSpace($location)) {
    $location = 'eastus2'
    Set-EnvValue -Name 'AZURE_LOCATION' -Value $location
}
if ($location -in @('westeurope', 'francecentral')) {
    Write-Warning "AZURE_LOCATION is set to '$location'. Some tenants restrict Conditional Access / Entra automation identities or specific SKUs (for example Flex Consumption) via Azure Policy in this region. If provisioning fails with a policy-denied error, retry with a different region such as eastus2."
}

# ---------------------------------------------------------------------------
# 3. Common defaults persisted regardless of mode
# ---------------------------------------------------------------------------
Set-EnvValueIfMissing -Name 'EMERGENCY_ACCESS_GROUP_ID' -Value ''
Set-EnvValueIfMissing -Name 'EMERGENCY_ACCESS_USER1_ID' -Value ''
Set-EnvValueIfMissing -Name 'EMERGENCY_ACCESS_USER1_UPN' -Value ''
Set-EnvValueIfMissing -Name 'EMERGENCY_ACCESS_USER2_ID' -Value ''
Set-EnvValueIfMissing -Name 'EMERGENCY_ACCESS_USER2_UPN' -Value ''
Set-EnvValueIfMissing -Name 'EMERGENCY_ACCESS_AU_ID' -Value ''
Set-EnvValueIfMissing -Name 'EMERGENCY_ACCESS_USER_PREFIX' -Value 'emergency-access'
Set-EnvValueIfMissing -Name 'AZD_SKIP_TENANT_BOOTSTRAP' -Value 'false'
Set-EnvValueIfMissing -Name 'AZD_SKIP_RESTRICTED_AU' -Value 'false'
Set-EnvValueIfMissing -Name 'AZD_ENABLE_TAP_POLICY' -Value 'false'
Set-EnvValueIfMissing -Name 'AZD_CREATED_USER1_ID' -Value ''
Set-EnvValueIfMissing -Name 'AZD_CREATED_USER2_ID' -Value ''
Set-EnvValueIfMissing -Name 'AZD_CREATED_GROUP_ID' -Value ''
Set-EnvValueIfMissing -Name 'AZD_CREATED_AU_ID' -Value ''
Set-EnvValueIfMissing -Name 'AZD_CREATED_FUNCTION_AAD_APP_OBJECT_ID' -Value ''

foreach ($booleanName in @('AZD_SKIP_TENANT_BOOTSTRAP', 'AZD_SKIP_RESTRICTED_AU', 'AZD_ENABLE_TAP_POLICY')) {
    $booleanValue = Get-EnvValue -Name $booleanName
    if ($booleanValue -notin @('true', 'false')) {
        throw "$booleanName must be exactly 'true' or 'false'; found '$booleanValue'."
    }
}

$userPrefix = Get-EnvValue -Name 'EMERGENCY_ACCESS_USER_PREFIX'
if ($userPrefix -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{1,48}[a-zA-Z0-9]$') {
    throw 'EMERGENCY_ACCESS_USER_PREFIX must be 3-50 characters containing only letters, digits, and internal hyphens.'
}

$configuredGroupId = Get-EnvValue -Name 'EMERGENCY_ACCESS_GROUP_ID'
if ($configuredGroupId) {
    $parsedGroupId = [guid]::Empty
    if (-not [guid]::TryParse($configuredGroupId, [ref]$parsedGroupId)) {
        throw 'EMERGENCY_ACCESS_GROUP_ID must be a GUID when supplied.'
    }
}

# ---------------------------------------------------------------------------
# 4. Mode-specific validation and defaults
# ---------------------------------------------------------------------------
switch ($deploymentMode) {
    'automation-scheduled' {
        Set-EnvValueIfMissing -Name 'AUTOMATION_RECURRENCE_HOURS' -Value '1'
        $hours = 0
        if (-not [int]::TryParse((Get-EnvValue -Name 'AUTOMATION_RECURRENCE_HOURS'), [ref]$hours) -or $hours -lt 1 -or $hours -gt 168) {
            throw 'AUTOMATION_RECURRENCE_HOURS must be an integer from 1 through 168.'
        }
    }
    'function-scheduled' {
        Set-EnvValueIfMissing -Name 'REMEDIATION_SCHEDULE_CRON' -Value '0 */15 * * * *'
    }
    'logicapp-scheduled' {
        Set-EnvValueIfMissing -Name 'LOGICAPP_RECURRENCE_MINUTES' -Value '15'
        $minutes = 0
        if (-not [int]::TryParse((Get-EnvValue -Name 'LOGICAPP_RECURRENCE_MINUTES'), [ref]$minutes) -or $minutes -lt 1 -or $minutes -gt 10080) {
            throw 'LOGICAPP_RECURRENCE_MINUTES must be an integer from 1 through 10080.'
        }
    }
    'sentinel-function' {
        Write-Host ''
        Write-Host 'sentinel-function mode requires an existing Sentinel-enabled Log Analytics workspace.'

        $workspaceName = Get-RequiredEnvValue -Name 'SENTINEL_WORKSPACE_NAME' `
            -Prompt 'Existing Sentinel-enabled Log Analytics workspace name' `
            -IsInteractive $isInteractive

        $workspaceRg = Get-RequiredEnvValue -Name 'SENTINEL_WORKSPACE_RESOURCE_GROUP' `
            -Prompt 'Resource group containing the Sentinel workspace' `
            -IsInteractive $isInteractive

        $workspaceSubId = Get-EnvValue -Name 'SENTINEL_WORKSPACE_SUBSCRIPTION_ID'
        if ([string]::IsNullOrWhiteSpace($workspaceSubId)) {
            $workspaceSubId = Get-EnvValue -Name 'AZURE_SUBSCRIPTION_ID'
            Set-EnvValue -Name 'SENTINEL_WORKSPACE_SUBSCRIPTION_ID' -Value $workspaceSubId
        }

        Test-SentinelWorkspace -WorkspaceName $workspaceName -ResourceGroup $workspaceRg -SubscriptionId $workspaceSubId

        $sentinelAutomationPrincipalId = & az ad sp list --display-name 'Azure Security Insights' --query '[0].id' --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $sentinelAutomationPrincipalId) {
            Set-EnvValue -Name 'SENTINEL_AUTOMATION_PRINCIPAL_ID' -Value $sentinelAutomationPrincipalId
        }
        else {
            Set-EnvValue -Name 'SENTINEL_AUTOMATION_PRINCIPAL_ID' -Value ''
            Write-Warning "Could not resolve the 'Azure Security Insights' service principal. The postprovision hook will retry the Microsoft Sentinel Automation Contributor role assignment."
        }

        # The Entra app registration that protects the Function App's HTTP trigger must exist
        # before infra/main.bicep runs, because the client ID is a bicep input parameter.
        $envName = Get-RequiredEnvValue -Name 'AZURE_ENV_NAME' -Prompt 'azd environment name' -IsInteractive $isInteractive
        $displayName = "azd-emergency-access-function-$envName"

        Write-Host "Ensuring Entra application registration '$displayName' exists (Easy Auth V2 resource for the protected Function HTTP trigger)..."
        $app = Initialize-FunctionAadApplication -DisplayName $displayName

        Set-EnvValue -Name 'FUNCTION_AAD_CLIENT_ID' -Value $app.AppId
        Set-EnvValue -Name 'FUNCTION_AAD_APP_OBJECT_ID' -Value $app.ObjectId
        if ($app.Created) {
            Set-EnvValue -Name 'AZD_CREATED_FUNCTION_AAD_APP_OBJECT_ID' -Value $app.ObjectId
        }
        Write-Host "FUNCTION_AAD_CLIENT_ID = $($app.AppId)" -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Preprovision validation complete.' -ForegroundColor Cyan
