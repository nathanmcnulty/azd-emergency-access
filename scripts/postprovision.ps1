#Requires -Version 7.0
<#
.SYNOPSIS
    azd postprovision hook for azd-emergency-access.

.DESCRIPTION
    Runs after `azd provision` has created the Azure resources for the selected AZD_DEPLOYMENT_MODE.
    Performs, in order:

      1. Idempotent Microsoft Entra tenant bootstrap (break-glass users, security group, restricted
         management administrative unit) unless AZD_SKIP_TENANT_BOOTSTRAP is 'true'.
      2. Temporary Access Pass (TAP) enablement, per AZD_ENABLE_TAP_POLICY / interactive prompt.
      3. Idempotent Microsoft Graph application permission grants (Policy.Read.All,
         Policy.ReadWrite.ConditionalAccess) to the mode-appropriate workload identity.
      4. Patching the deployed resource's emergency access group ID setting with whatever group ID
         was resolved/created in step 1 (infra/main.bicep may have deployed with an empty value).
      5. sentinel-function only: patching the Function App's Easy Auth V2 allowed caller identities
         with the Sentinel playbook's managed identity, and attempting the Sentinel Automation
         Contributor role assignment on the playbook's resource group.
      6. Publishing runtime content: the Automation runbook (automation-scheduled) or the Function
         App package (function-scheduled, sentinel-function). No `services:` block exists in
         azure.yaml because azd cannot conditionally skip a service's deploy stage per mode; this
         hook is the "secure deploy hook" fallback described in the template's README.

    Every step is safe to re-run: existing tenant objects are reused, existing role/app-role
    assignments are detected and skipped, and resource configuration patches are idempotent.

    No password or Temporary Access Pass value is ever logged, written to a file, returned from a
    function, persisted to an azd environment value, or included in a Bicep/ARM output.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\shared\PreprovisionSupport.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\shared\TenantBootstrap.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\shared\TemporaryAccessPass.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\shared\GraphAppRoleAssignment.psm1') -Force

# =============================================================================
# Local helper functions (defined before use -- PowerShell does not hoist function
# definitions within a script, so these must appear before the call sites below).
# =============================================================================
function Update-LogicAppParameterValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $LogicAppName,
        [Parameter(Mandatory = $true)] [string] $ParameterName,
        [Parameter(Mandatory = $true)] [string] $ParameterValue
    )

    $resourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName"
    $currentJson = az rest --method get --uri "https://management.azure.com$($resourceId)?api-version=2019-05-01" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $currentJson) {
        Write-Warning "Failed to read Logic App '$LogicAppName' to update its $ParameterName parameter value. Set it manually in the Azure portal (Logic App > Workflow settings > Parameters) or via az rest PUT."
        return
    }

    $resource = $currentJson | ConvertFrom-Json -Depth 30
    if (-not $resource.properties.PSObject.Properties['parameters'] -or $null -eq $resource.properties.parameters) {
        $resource.properties | Add-Member -MemberType NoteProperty -Name 'parameters' -Value ([pscustomobject]@{}) -Force
    }
    $resource.properties.parameters | Add-Member -MemberType NoteProperty -Name $ParameterName -Value ([pscustomobject]@{ value = $ParameterValue }) -Force
    $resource.properties.state = 'Enabled'

    $body = $resource | ConvertTo-Json -Depth 30
    $tempFile = New-TemporaryFile
    try {
        Set-Content -Path $tempFile -Value $body -NoNewline
        az rest --method put --uri "https://management.azure.com$($resourceId)?api-version=2019-05-01" --body "@$tempFile" --headers 'Content-Type=application/json' -o none
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to update Logic App '$LogicAppName' parameter '$ParameterName'. Set it manually in the Azure portal (Logic App > Workflow settings > Parameters)."
        }
        else {
            Write-Host "Updated Logic App parameter '$ParameterName'." -ForegroundColor Green
        }
    }
    finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }
}

function Update-FunctionAllowedCallerIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $FunctionAppName,
        [Parameter(Mandatory = $true)] [string] $PrincipalId
    )

    $resourceId = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName/config/authsettingsV2"
    $currentJson = az rest --method get --uri "https://management.azure.com$($resourceId)?api-version=2023-12-01" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $currentJson) {
        Write-Warning "Failed to read Function App '$FunctionAppName' authsettingsV2 to authorize the Sentinel playbook. Add its principal ID ($PrincipalId) to Authentication > Identity provider > Allowed identities manually in the Azure portal."
        return
    }

    $resource = $currentJson | ConvertFrom-Json -Depth 30
    $policy = $resource.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy
    $identities = @($policy.allowedPrincipals.identities)

    if ($identities -contains $PrincipalId) {
        Write-Host 'The Sentinel playbook identity is already an allowed caller.' -ForegroundColor Green
        return
    }

    $identities += $PrincipalId
    $policy.allowedPrincipals.identities = $identities

    $body = $resource | ConvertTo-Json -Depth 30
    $tempFile = New-TemporaryFile
    try {
        Set-Content -Path $tempFile -Value $body -NoNewline
        az rest --method put --uri "https://management.azure.com$($resourceId)?api-version=2023-12-01" --body "@$tempFile" --headers 'Content-Type=application/json' -o none
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to authorize the Sentinel playbook identity ($PrincipalId) as an allowed caller. Add it manually in the Azure portal (Function App > Authentication > Identity provider > Edit > Allowed identities)."
        }
        else {
            Write-Host 'Authorized the Sentinel playbook managed identity to call the protected HTTP function.' -ForegroundColor Green
        }
    }
    finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }
}

function Grant-SentinelAutomationContributorRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
        [Parameter(Mandatory = $true)] [string] $SubscriptionId
    )

    $roleDefinitionId = 'f4c81013-99ee-4d62-a7ee-b3f1f648599a' # Microsoft Sentinel Automation Contributor
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

    $sentinelSpId = az ad sp list --display-name 'Azure Security Insights' --query '[0].id' -o tsv 2>$null
    if (-not $sentinelSpId) {
        Write-Warning "Could not find the 'Azure Security Insights' first-party service principal in this tenant."
        Write-Host "To finish manually once you locate the correct service principal object ID <spId>: az role assignment create --assignee-object-id <spId> --assignee-principal-type ServicePrincipal --role $roleDefinitionId --scope $scope" -ForegroundColor Cyan
        return
    }

    $existing = az role assignment list --assignee $sentinelSpId --scope $scope --role $roleDefinitionId -o json 2>$null | ConvertFrom-Json
    if (@($existing).Count -gt 0) {
        Write-Host 'Microsoft Sentinel Automation Contributor is already assigned on this resource group.' -ForegroundColor Green
        return
    }

    az role assignment create --assignee-object-id $sentinelSpId --assignee-principal-type ServicePrincipal --role $roleDefinitionId --scope $scope -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Failed to assign Microsoft Sentinel Automation Contributor on the playbook resource group (this typically requires Owner or User Access Administrator on the resource group).'
        Write-Host "To finish manually: az role assignment create --assignee-object-id $sentinelSpId --assignee-principal-type ServicePrincipal --role $roleDefinitionId --scope $scope" -ForegroundColor Cyan
    }
    else {
        Write-Host 'Assigned Microsoft Sentinel Automation Contributor on the playbook resource group.' -ForegroundColor Green
    }
}

Write-Host '=== azd-emergency-access: postprovision ===' -ForegroundColor Cyan

$isInteractive = Test-InteractiveSession
$deploymentMode = Get-EnvValue -Name 'AZD_DEPLOYMENT_MODE'
$resourceGroupName = Get-EnvValue -Name 'RESOURCE_GROUP_NAME'
$subscriptionId = Get-EnvValue -Name 'AZURE_SUBSCRIPTION_ID'

if ([string]::IsNullOrWhiteSpace($deploymentMode)) {
    throw 'AZD_DEPLOYMENT_MODE is not set. Run azd provision (which runs preprovision.ps1 first) before postprovision.'
}

Write-Host "Deployment mode: $deploymentMode"
Write-Host "Resource group: $resourceGroupName"

# =============================================================================
# 1-2. Tenant bootstrap + TAP
# =============================================================================
$groupId = Get-EnvValue -Name 'EMERGENCY_ACCESS_GROUP_ID'
$skipBootstrap = (Get-EnvValue -Name 'AZD_SKIP_TENANT_BOOTSTRAP') -eq 'true'

if ($skipBootstrap) {
    Write-Host ''
    Write-Host 'AZD_SKIP_TENANT_BOOTSTRAP=true: skipping tenant bootstrap (users/group/administrative unit/TAP).' -ForegroundColor Yellow
    if ([string]::IsNullOrWhiteSpace($groupId)) {
        Write-Warning 'EMERGENCY_ACCESS_GROUP_ID is empty and tenant bootstrap was skipped. Remediation resources will have no group configured. Set EMERGENCY_ACCESS_GROUP_ID and re-run: azd env set EMERGENCY_ACCESS_GROUP_ID <group-object-id>; azd provision'
    }
}
else {
    $graphConnected = $false
    try {
        if ($isInteractive) {
            Write-Host ''
            Write-Host 'Connecting to Microsoft Graph (interactive sign-in; a browser window may open)...'
            Connect-MgGraph -NoWelcome -Scopes @(
                'User.ReadWrite.All',
                'Group.ReadWrite.All',
                'AdministrativeUnit.ReadWrite.All',
                'RoleManagement.ReadWrite.Directory',
                'Policy.ReadWrite.AuthenticationMethod',
                'UserAuthenticationMethod.ReadWrite.All',
                'Application.Read.All',
                'AppRoleAssignment.ReadWrite.All'
            ) | Out-Null
            $graphConnected = $true
        }
        else {
            $graphToken = az account get-access-token --resource-type ms-graph --query accessToken --output tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and $graphToken) {
                Write-Host 'Connecting to Microsoft Graph using the current Azure CLI identity (no stored credential)...'
                Connect-MgGraph -AccessToken (ConvertTo-SecureString -String $graphToken -AsPlainText -Force) -NoWelcome | Out-Null
                $graphConnected = $true
            }
            else {
                Write-Warning 'Could not obtain a Microsoft Graph token for the current Azure CLI identity. Skipping tenant bootstrap and TAP for this run. Re-run interactively or set AZD_SKIP_TENANT_BOOTSTRAP=true and provide existing object IDs.'
            }
        }
    }
    catch {
        Write-Warning "Could not connect to Microsoft Graph: $($_.Exception.Message). Skipping tenant bootstrap and TAP for this run."
    }

    if ($graphConnected) {
        try {
            Write-Host ''
            Write-Host '--- Tenant bootstrap: users, group, restricted administrative unit ---' -ForegroundColor Cyan

            $userPrefix = Get-EnvValue -Name 'EMERGENCY_ACCESS_USER_PREFIX'
            if ([string]::IsNullOrWhiteSpace($userPrefix)) { $userPrefix = 'emergency-access' }

            $context = Get-MgContext
            $domain = ($context.Account -split '@')[1]
            $orgJson = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=verifiedDomains'
            $defaultDomain = ($orgJson.value[0].verifiedDomains | Where-Object { $_.isDefault }) | Select-Object -First 1
            if ($defaultDomain) { $domain = $defaultDomain.name }

            $user1 = Get-OrNewEmergencyAccessUser `
                -ExistingUserId (Get-EnvValue -Name 'EMERGENCY_ACCESS_USER1_ID') `
                -ExistingUserUpn (Get-EnvValue -Name 'EMERGENCY_ACCESS_USER1_UPN') `
                -NewUserPrefix "$userPrefix-1" `
                -Domain $domain
            Write-Host "User 1: $($user1.UserPrincipalName) ($(if ($user1.Created) { 'created' } else { 'reused' }))"
            if ($user1.Created) { Set-EnvValue -Name 'AZD_CREATED_USER1_ID' -Value $user1.Id }

            $user2 = Get-OrNewEmergencyAccessUser `
                -ExistingUserId (Get-EnvValue -Name 'EMERGENCY_ACCESS_USER2_ID') `
                -ExistingUserUpn (Get-EnvValue -Name 'EMERGENCY_ACCESS_USER2_UPN') `
                -NewUserPrefix "$userPrefix-2" `
                -Domain $domain
            Write-Host "User 2: $($user2.UserPrincipalName) ($(if ($user2.Created) { 'created' } else { 'reused' }))"
            if ($user2.Created) { Set-EnvValue -Name 'AZD_CREATED_USER2_ID' -Value $user2.Id }

            $group = Get-OrNewEmergencyAccessGroup `
                -ExistingGroupId (Get-EnvValue -Name 'EMERGENCY_ACCESS_GROUP_ID') `
                -GroupDisplayName "$userPrefix-group" `
                -MemberUserIds @($user1.Id, $user2.Id)
            Write-Host "Group: $($group.DisplayName) ($(if ($group.Created) { 'created' } else { 'reused' }))"
            if ($group.Created) { Set-EnvValue -Name 'AZD_CREATED_GROUP_ID' -Value $group.Id }
            $groupId = $group.Id

            $skipRestrictedAu = (Get-EnvValue -Name 'AZD_SKIP_RESTRICTED_AU') -eq 'true'
            $au = $null
            if ($skipRestrictedAu) {
                Write-Host 'AZD_SKIP_RESTRICTED_AU=true: not creating or modifying a restricted management administrative unit.' -ForegroundColor Yellow
            }
            else {
                $au = Get-OrNewRestrictedManagementAdministrativeUnit `
                    -ExistingAdministrativeUnitId (Get-EnvValue -Name 'EMERGENCY_ACCESS_AU_ID') `
                    -DisplayName "$userPrefix-restricted-au" `
                    -MemberObjectIds @($user1.Id, $user2.Id, $group.Id)
                Write-Host "Restricted administrative unit: $($au.DisplayName) ($(if ($au.Created) { 'created' } else { 'reused' }))"
                if ($au.Created) { Set-EnvValue -Name 'AZD_CREATED_AU_ID' -Value $au.Id }
                Write-Host 'Restricted management is defense in depth; Global Administrators and Privileged Role Administrators can still manage restricted objects.' -ForegroundColor DarkYellow
            }

            Write-Host 'Ensuring both users hold a permanent, tenant-wide Global Administrator assignment...'
            Grant-GlobalAdministratorRole -UserId $user1.Id
            Grant-GlobalAdministratorRole -UserId $user2.Id

            Set-EnvValue -Name 'EMERGENCY_ACCESS_GROUP_ID' -Value $group.Id
            Set-EnvValue -Name 'EMERGENCY_ACCESS_USER1_ID' -Value $user1.Id
            Set-EnvValue -Name 'EMERGENCY_ACCESS_USER1_UPN' -Value $user1.UserPrincipalName
            Set-EnvValue -Name 'EMERGENCY_ACCESS_USER2_ID' -Value $user2.Id
            Set-EnvValue -Name 'EMERGENCY_ACCESS_USER2_UPN' -Value $user2.UserPrincipalName
            if ($au) { Set-EnvValue -Name 'EMERGENCY_ACCESS_AU_ID' -Value $au.Id }

            # -----------------------------------------------------------------------
            # Temporary Access Pass
            # -----------------------------------------------------------------------
            $enableTap = (Get-EnvValue -Name 'AZD_ENABLE_TAP_POLICY') -eq 'true'
            $doTap = $enableTap

            if (-not $enableTap -and $isInteractive) {
                Write-Host ''
                $answer = Read-Host 'AZD_ENABLE_TAP_POLICY is false. Enable a Temporary Access Pass policy scoped to the emergency access group now and issue 2-hour TAPs for both users? (y/N)'
                $doTap = $answer -match '^(y|yes)$'
            }
            elseif (-not $enableTap) {
                Write-Host 'AZD_ENABLE_TAP_POLICY=false (non-interactive): skipping Temporary Access Pass setup.' -ForegroundColor Yellow
            }

            if ($doTap) {
                try {
                    Write-Host ''
                    Write-Host '--- Temporary Access Pass ---' -ForegroundColor Cyan
                    Enable-TemporaryAccessPassPolicy -GroupId $groupId
                    Write-Host 'Temporary Access Pass authentication method policy is enabled, scoped to the emergency access group.'

                    if (-not $isInteractive) {
                        Write-Warning 'TAP policy was enabled, but TAP values can only be displayed safely in an attended interactive console. No TAPs were created. Re-run azd provision interactively to create and display them once.'
                    }

                    foreach ($user in @($user1, $user2)) {
                        if (-not $isInteractive) { continue }
                        if (Test-ActiveTemporaryAccessPass -UserId $user.Id) {
                            Write-Host "$($user.UserPrincipalName) already has an active Temporary Access Pass; Microsoft Graph cannot redisplay its value, so no new pass was created. Delete the existing pass first if you need a new one." -ForegroundColor Yellow
                            continue
                        }

                        $tap = New-ReusableTemporaryAccessPass -UserId $user.Id
                        Write-Host ''
                        Write-Host "Temporary Access Pass for $($user.UserPrincipalName) (valid 2 hours, shown once, NOT stored anywhere):" -ForegroundColor Magenta
                        Write-Host "  $tap" -ForegroundColor Magenta
                        Write-Host ''
                        # $tap deliberately falls out of scope here; it is never logged, returned, or persisted.
                    }

                    Write-Host 'Sign in to each break-glass account with its Temporary Access Pass and immediately register at least two passkeys (FIDO2 security keys) so the account no longer depends on a password.' -ForegroundColor Cyan
                }
                catch {
                    Write-Warning "Temporary Access Pass setup failed: $($_.Exception.Message)"
                    Write-Host 'To finish manually: enable the Temporary Access Pass authentication method policy (Entra admin center > Authentication methods), scope it to the emergency access group, create a 2-hour reusable Temporary Access Pass for each break-glass user, sign in with it, and register at least two passkeys.' -ForegroundColor Cyan
                }
            }
            else {
                Write-Host 'To enable this later: azd env set AZD_ENABLE_TAP_POLICY true; azd provision. Then sign in to each break-glass account with its Temporary Access Pass and register at least two passkeys.' -ForegroundColor Cyan
            }
        }
        catch {
            Write-Warning "Tenant bootstrap failed: $($_.Exception.Message)"
            Write-Host 'Provisioning will continue. Re-run azd provision after resolving the error above (typically insufficient Graph permissions: User.ReadWrite.All, Group.ReadWrite.All, AdministrativeUnit.ReadWrite.All, RoleManagement.ReadWrite.Directory), or set required env values directly and set AZD_SKIP_TENANT_BOOTSTRAP=true to bypass this step.' -ForegroundColor Yellow
        }
        finally {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

# =============================================================================
# 3. Graph application permission grants for the mode-appropriate workload identity
# =============================================================================
Write-Host ''
Write-Host '--- Microsoft Graph application permission grants ---' -ForegroundColor Cyan

$workloadPrincipalId = switch ($deploymentMode) {
    'automation-scheduled' { Get-EnvValue -Name 'AUTOMATION_ACCOUNT_PRINCIPAL_ID' }
    'function-scheduled' { Get-EnvValue -Name 'FUNCTION_APP_IDENTITY_PRINCIPAL_ID' }
    'logicapp-scheduled' { Get-EnvValue -Name 'LOGIC_APP_SCHEDULED_PRINCIPAL_ID' }
    'sentinel-function' { Get-EnvValue -Name 'FUNCTION_APP_IDENTITY_PRINCIPAL_ID' }
}

if ([string]::IsNullOrWhiteSpace($workloadPrincipalId)) {
    Write-Warning "Could not determine the workload managed identity's principal ID for mode '$deploymentMode' from azd outputs. Skipping Graph app role assignment; grant Policy.Read.All and Policy.ReadWrite.ConditionalAccess manually."
}
else {
    if (-not (Get-MgContext)) {
        # Reuse the az CLI's own login for a lightweight, non-interactive Graph token; app role
        # assignment only needs Application.ReadWrite.All-equivalent access via AppRoleAssignment.
        try {
            $graphToken = az account get-access-token --resource-type ms-graph --query accessToken -o tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and $graphToken) {
                Connect-MgGraph -AccessToken (ConvertTo-SecureString -String $graphToken -AsPlainText -Force) -NoWelcome | Out-Null
            }
        }
        catch {
            Write-Warning "Could not obtain a Microsoft Graph token from the Azure CLI context: $($_.Exception.Message)"
        }
    }

    if (Get-MgContext) {
        $roleResults = Grant-GraphAppRoleAssignment -PrincipalId $workloadPrincipalId -AppRoleValue @('Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess')
        foreach ($result in $roleResults) {
            switch ($result.status) {
                'granted' { Write-Host "Granted $($result.appRole) to the workload identity." -ForegroundColor Green }
                'already-assigned' { Write-Host "$($result.appRole) is already assigned to the workload identity." }
                'failed' { Write-Warning "Failed to grant $($result.appRole): $($result.error). Grant it manually: az ad app permission ... or via the Entra admin center (Enterprise applications > <identity> > Permissions), or Connect-MgGraph and New-MgServicePrincipalAppRoleAssignment." }
            }
        }
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }
    else {
        Write-Warning "Not connected to Microsoft Graph; skipping app role assignment for principal $workloadPrincipalId. Grant Policy.Read.All and Policy.ReadWrite.ConditionalAccess to it manually."
    }
}

# =============================================================================
# 4. Patch the deployed resource's emergency access group ID
# =============================================================================
if (-not [string]::IsNullOrWhiteSpace($groupId)) {
    Write-Host ''
    Write-Host '--- Synchronizing emergency access group ID onto deployed resources ---' -ForegroundColor Cyan

    switch ($deploymentMode) {
        'automation-scheduled' {
            $automationAccountName = Get-EnvValue -Name 'AUTOMATION_ACCOUNT_NAME'
            if ($automationAccountName) {
                $resourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Automation/automationAccounts/$automationAccountName/variables/EMERGENCY_ACCESS_GROUP_ID"
                $body = @{ properties = @{ value = $groupId; isEncrypted = $false } } | ConvertTo-Json -Depth 5
                az rest --method put --uri "https://management.azure.com$($resourceId)?api-version=2023-11-01" --body $body --headers 'Content-Type=application/json' -o none
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to update the EMERGENCY_ACCESS_GROUP_ID automation variable. Set it manually: az automation variable update --automation-account-name $automationAccountName -g $resourceGroupName --name EMERGENCY_ACCESS_GROUP_ID --value $groupId"
                }
                else {
                    Write-Host "Updated automation variable EMERGENCY_ACCESS_GROUP_ID." -ForegroundColor Green
                }
            }
        }
        'logicapp-scheduled' {
            $logicAppName = Get-EnvValue -Name 'LOGIC_APP_SCHEDULED_NAME'
            if ($logicAppName) {
                Update-LogicAppParameterValue -ResourceGroupName $resourceGroupName -LogicAppName $logicAppName -ParameterName 'EmergencyAccountsGroupObjectId' -ParameterValue $groupId
            }
        }
        { $_ -in @('function-scheduled', 'sentinel-function') } {
            $functionAppName = Get-EnvValue -Name 'FUNCTION_APP_NAME'
            if ($functionAppName) {
                az functionapp config appsettings set --name $functionAppName --resource-group $resourceGroupName --settings "EMERGENCY_ACCESS_GROUP_ID=$groupId" -o none
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to update the Function App's EMERGENCY_ACCESS_GROUP_ID app setting. Set it manually: az functionapp config appsettings set --name $functionAppName -g $resourceGroupName --settings EMERGENCY_ACCESS_GROUP_ID=$groupId"
                }
                else {
                    Write-Host 'Updated Function App setting EMERGENCY_ACCESS_GROUP_ID.' -ForegroundColor Green
                }
            }
        }
    }
}

# =============================================================================
# 5. sentinel-function only: Easy Auth caller allow-list + Sentinel Automation Contributor
# =============================================================================
if ($deploymentMode -eq 'sentinel-function') {
    Write-Host ''
    Write-Host '--- sentinel-function: authorizing the playbook to call the protected function ---' -ForegroundColor Cyan

    $functionAppName = Get-EnvValue -Name 'FUNCTION_APP_NAME'
    $playbookPrincipalId = Get-EnvValue -Name 'SENTINEL_PLAYBOOK_PRINCIPAL_ID'

    if ($functionAppName -and $playbookPrincipalId) {
        Update-FunctionAllowedCallerIdentity -ResourceGroupName $resourceGroupName -FunctionAppName $functionAppName -PrincipalId $playbookPrincipalId
    }
    else {
        Write-Warning 'Could not determine the Function App name or Sentinel playbook principal ID from azd outputs; the protected HTTP trigger will reject the playbook until this is fixed manually.'
    }

    Write-Host ''
    Write-Host '--- sentinel-function: Microsoft Sentinel Automation Contributor role on the playbook resource group ---' -ForegroundColor Cyan
    Grant-SentinelAutomationContributorRole -ResourceGroupName $resourceGroupName -SubscriptionId $subscriptionId
}

# =============================================================================
# 6. Publish runtime content
# =============================================================================
Write-Host ''
Write-Host '--- Publishing runtime content ---' -ForegroundColor Cyan

switch ($deploymentMode) {
    'automation-scheduled' {
        & (Join-Path $PSScriptRoot 'Publish-AutomationRunbook.ps1') `
            -ResourceGroupName $resourceGroupName `
            -AutomationAccountName (Get-EnvValue -Name 'AUTOMATION_ACCOUNT_NAME') `
            -RunbookName 'Invoke-EmergencyAccessRemediation'
    }
    { $_ -in @('function-scheduled', 'sentinel-function') } {
        & (Join-Path $PSScriptRoot 'Publish-FunctionApp.ps1') `
            -ResourceGroupName $resourceGroupName `
            -FunctionAppName (Get-EnvValue -Name 'FUNCTION_APP_NAME') `
            -DeploymentMode $deploymentMode
    }
}

Write-Host ''
Write-Host 'Postprovision complete.' -ForegroundColor Cyan
