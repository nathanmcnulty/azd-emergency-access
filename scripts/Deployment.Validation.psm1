Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Tenant.Guards.psm1') -Force

$script:ValidationEnvironmentNames = @(
    'AZURE_ENV_NAME',
    'AZURE_SUBSCRIPTION_ID',
    'AZURE_TENANT_ID',
    'AZURE_RESOURCE_GROUP',
    'AZD_DEPLOYMENT_MODE',
    'AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT',
    'AZD_EMERGENCY_USER1_UPN',
    'AZD_EMERGENCY_USER1_ID',
    'AZD_EMERGENCY_USER2_UPN',
    'AZD_EMERGENCY_USER2_ID',
    'AZD_EMERGENCY_USER3_UPN',
    'AZD_EMERGENCY_USER3_ID',
    'AZD_ENABLE_SIGNIN_ALERTS',
    'AZURE_SIGNIN_ALERT_RULE_ID',
    'AZURE_SIGNIN_ALERT_ACTION_GROUP_ID',
    'AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS',
    'AZURE_SENTINEL_SIGNIN_RULE_ID',
    'AZURE_SENTINEL_ADMIN_ACTIVITY_RULE_ID',
    'AZURE_SENTINEL_ACCOUNT_CHANGE_RULE_ID',
    'AZURE_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID',
    'AZURE_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID',
    'AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID',
    'AZURE_FUNCTION_APP_NAME',
    'AZURE_PLAYBOOK_PRINCIPAL_ID',
    'AZD_FUNCTION_AUTH_AUDIENCE',
    'AZD_SENTINEL_TEAMS_DELIVERY_MODE',
    'AZD_SENTINEL_OUTLOOK_CONNECTION_RESOURCE_ID'
)

function Test-EmergencySentinelFunctionAuthentication {
    [CmdletBinding()]
    param()

    if (-not $env:AZURE_FUNCTION_APP_NAME -or -not $env:AZURE_PLAYBOOK_PRINCIPAL_ID -or
        -not $env:AZD_FUNCTION_AUTH_AUDIENCE) {
        throw 'Sentinel Function authentication outputs are incomplete.'
    }

    $functionJson = & az functionapp show --resource-group $env:AZURE_RESOURCE_GROUP `
        --name $env:AZURE_FUNCTION_APP_NAME --query '{id:id,defaultHostName:defaultHostName}' `
        --output json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $functionJson) {
        throw 'Unable to inspect the Sentinel Function.'
    }
    $function = $functionJson | ConvertFrom-Json
    if (-not $function.id -or -not $function.defaultHostName) {
        throw 'Sentinel Function resource data is incomplete.'
    }

    $authJson = & az resource show --ids "$($function.id)/config/authsettingsV2" `
        --api-version 2024-04-01 --output json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $authJson) {
        throw 'Unable to inspect Sentinel Function Easy Auth.'
    }
    $auth = $authJson | ConvertFrom-Json
    $allowedAudiences = @($auth.properties.identityProviders.azureActiveDirectory.validation.allowedAudiences)
    $allowedIdentities = @($auth.properties.identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities)
    if ($auth.properties.platform.enabled -ne $true -or
        $auth.properties.globalValidation.requireAuthentication -ne $true -or
        $auth.properties.globalValidation.unauthenticatedClientAction -ne 'Return401' -or
        $allowedAudiences.Count -ne 1 -or
        $allowedAudiences[0] -ne $env:AZD_FUNCTION_AUTH_AUDIENCE -or
        $allowedIdentities.Count -ne 1 -or
        $allowedIdentities[0] -ne $env:AZURE_PLAYBOOK_PRINCIPAL_ID) {
        throw 'Sentinel Function Easy Auth does not enforce the exact audience and playbook principal.'
    }

    $response = Invoke-WebRequest -Method Post `
        -Uri "https://$($function.defaultHostName)/api/remediate" `
        -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck
    if ([int] $response.StatusCode -ne 401) {
        throw 'The Sentinel Function did not return HTTP 401 to an unauthenticated request.'
    }
}

function Invoke-EmergencySentinelNotificationDelivery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $PlaybookResourceId)

    $triggerName = 'Microsoft_Sentinel_incident'
    $managementBase = "https://management.azure.com$PlaybookResourceId"
    $callbackJson = & az rest --method post `
        --url "$managementBase/triggers/$triggerName/listCallbackUrl?api-version=2019-05-01" `
        --output json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $callbackJson) {
        throw 'Unable to obtain the Sentinel notification trigger callback.'
    }
    $callback = $callbackJson | ConvertFrom-Json
    if (-not $callback.value) { throw 'The Sentinel notification trigger callback is unavailable.' }

    $trackingId = [guid]::NewGuid().ToString()
    $payload = @{
        object = @{
            id = "$PlaybookResourceId/providers/Microsoft.SecurityInsights/incidents/delivery-smoke-test"
            name = 'delivery-smoke-test'
            type = 'Microsoft.SecurityInsights/Incidents'
            properties = @{
                title = '[TEST] Emergency access notification delivery validation'
                description = 'Authorized azd delivery test. No emergency account or tenant object was changed.'
                severity = 'Informational'
                status = 'New'
                incidentNumber = 0
                incidentUrl = 'https://portal.azure.com/'
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress

    $response = Invoke-WebRequest -Method Post -Uri $callback.value -ContentType 'application/json' `
        -Headers @{ 'x-ms-client-tracking-id' = $trackingId } -Body $payload
    if ([int] $response.StatusCode -notin 200, 201, 202) {
        throw 'The Sentinel notification playbook did not accept the delivery test.'
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
    $run = $null
    do {
        Start-Sleep -Seconds 3
        $runsJson = & az rest --method get `
            --url "$managementBase/runs?api-version=2019-05-01" --output json --only-show-errors
        if ($LASTEXITCODE -ne 0 -or -not $runsJson) {
            throw 'Unable to inspect Sentinel notification playbook runs.'
        }
        $runs = $runsJson | ConvertFrom-Json
        $run = @($runs.value) |
            Where-Object { $_.properties.correlation.clientTrackingId -eq $trackingId } |
            Select-Object -First 1
    } while ((-not $run -or $run.properties.status -in 'Running', 'Waiting') -and
        [DateTimeOffset]::UtcNow -lt $deadline)

    if (-not $run) { throw 'The Sentinel notification delivery run did not appear within 60 seconds.' }
    if ($run.properties.status -ne 'Succeeded') {
        throw 'The Sentinel notification delivery run did not succeed.'
    }

    $actionsJson = & az rest --method get `
        --url "$managementBase/runs/$($run.name)/actions?api-version=2019-05-01" `
        --output json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or -not $actionsJson) {
        throw 'Unable to inspect Sentinel notification delivery actions.'
    }
    $actions = @((($actionsJson | ConvertFrom-Json).value))
    $expectedActionNames = @(
        if ($env:AZD_SENTINEL_TEAMS_DELIVERY_MODE -eq 'workflow-webhook') {
            'Post_adaptive_card_to_Teams'
        }
        else {
            'Post_message_to_Teams_channel'
        }
        if ($env:AZD_SENTINEL_OUTLOOK_CONNECTION_RESOURCE_ID) {
            'Send_incident_email'
        }
    )
    foreach ($actionName in $expectedActionNames) {
        $action = @($actions | Where-Object name -eq $actionName)
        if ($action.Count -ne 1 -or $action[0].properties.status -ne 'Succeeded') {
            throw "Expected Sentinel notification action '$actionName' did not succeed."
        }
    }
    return $expectedActionNames
}

function Get-ProjectValidationDefinition {
    [CmdletBinding()]
    param()

    $repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

    New-AzdValidationCheckDefinition -Id 'context.template-root' -Phase context `
        -Title 'Template root is complete' -Summary 'azure.yaml exists at the repository root.' `
        -SideEffect none -Action ({
            if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot 'azure.yaml') -PathType Leaf)) {
                throw 'azure.yaml was not found.'
            }
        }.GetNewClosure())

    New-AzdValidationCheckDefinition -Id 'context.azure-session' -Phase context `
        -Title 'Azure context is exact' `
        -Summary 'The cached Azure CLI session matches the azd tenant and subscription.' `
        -SideEffect readOnly `
        -Remediation 'Use az login through the normal broker or browser flow, select the expected subscription, and rerun validation.' `
        -Action {
            foreach ($name in $script:ValidationEnvironmentNames) {
                [void] (Get-AzdEnvironmentValue $name)
            }
            $requiredValues = @(
                'AZURE_SUBSCRIPTION_ID',
                'AZURE_TENANT_ID',
                'AZD_DEPLOYMENT_MODE',
                'AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT',
                'AZD_ENABLE_SIGNIN_ALERTS',
                'AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS'
            )
            $missingValues = @($requiredValues | Where-Object {
                    -not [Environment]::GetEnvironmentVariable($_)
                })
            if ($missingValues.Count -gt 0) {
                return (New-AzdCheckFailure -Code 'context.requiredValueMissing' `
                    -Summary 'One or more required azd deployment values are missing.' `
                    -Expected 'Tenant, subscription, deployment mode, and all feature decision values.' `
                    -Details @{ missingValueNames = $missingValues } `
                    -Remediation 'Confirm provisioning completed and the expected azd environment is selected.')
            }
            $allowedModes = @('function-scheduled', 'automation-scheduled', 'logicapp-scheduled', 'sentinel-function')
            if ($env:AZD_DEPLOYMENT_MODE -notin $allowedModes) {
                return (New-AzdCheckFailure -Code 'context.deploymentModeInvalid' `
                    -Summary 'AZD_DEPLOYMENT_MODE is not a supported value.' `
                    -Expected $allowedModes -Details @{ value = $env:AZD_DEPLOYMENT_MODE } `
                    -Remediation 'Select a supported deployment mode and rerun validation.')
            }
            $booleanNames = @(
                'AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT',
                'AZD_ENABLE_SIGNIN_ALERTS',
                'AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS'
            )
            $invalidBooleans = @($booleanNames | Where-Object {
                    [Environment]::GetEnvironmentVariable($_) -notin @('true', 'false')
                })
            if ($invalidBooleans.Count -gt 0) {
                return (New-AzdCheckFailure -Code 'context.featureDecisionInvalid' `
                    -Summary 'One or more azd feature decisions are not boolean values.' `
                    -Expected 'true or false' -Details @{ invalidValueNames = $invalidBooleans } `
                    -Remediation 'Set every listed feature decision to true or false and rerun validation.')
            }
            try {
                Assert-AzdTenantContext
                New-AzdCheckOutcome -Summary 'The cached Azure CLI session matches the azd tenant and subscription.' `
                    -Expected 'One exact tenant and subscription.' -Actual 'Validated'
            }
            catch {
                $code = if ($_.Exception.Message -like 'Tenant context mismatch.*') {
                    'context.tenantMismatch'
                }
                elseif ($_.Exception.Message -like 'Azure subscription mismatch.*') {
                    'context.subscriptionMismatch'
                }
                else {
                    'context.sessionUnavailable'
                }
                New-AzdCheckFailure -Code $code -Summary 'The cached Azure CLI context could not be validated exactly.' `
                    -Expected 'One exact tenant and subscription.' `
                    -Remediation 'Correct the active Azure tenant and subscription using the normal broker or browser flow, then rerun validation.'
            }
        }

    New-AzdValidationCheckDefinition -Id 'infrastructure.resource-group' -Phase infrastructure `
        -Title 'Deployment resources are present' `
        -Summary 'The deployment resource group contains readable resources.' `
        -SideEffect readOnly -DependsOn 'context.azure-session' `
        -Remediation 'Confirm the resource group and Azure access, then rerun provisioning or validation.' `
        -Action {
            if (-not $env:AZURE_RESOURCE_GROUP) {
                return (New-AzdCheckFailure -Code 'infrastructure.resourceGroupMissing' `
                    -Summary 'AZURE_RESOURCE_GROUP is missing.' -Expected 'A deployed resource group name.' `
                    -Remediation 'Confirm infrastructure provisioning completed.')
            }
            try {
                $resourcesJson = & az resource list --resource-group $env:AZURE_RESOURCE_GROUP `
                    --query '[].{name:name,type:type}' --output json --only-show-errors
                if ($LASTEXITCODE -ne 0 -or -not $resourcesJson) { throw 'Resource query failed.' }
                $resources = @($resourcesJson | ConvertFrom-Json)
                if ($resources.Count -eq 0) {
                    return (New-AzdCheckFailure -Code 'infrastructure.resourceGroupEmpty' `
                        -Summary 'The deployment resource group contains no resources.' `
                        -Expected 'At least one deployed resource.' `
                        -Remediation 'Rerun provisioning and inspect the ARM deployment result.')
                }
                New-AzdCheckOutcome -Summary "Verified $($resources.Count) deployed resource(s)." `
                    -Expected 'At least one deployed resource.' -Actual ([ordered] @{ resourceCount = $resources.Count })
            }
            catch {
                New-AzdCheckFailure -Code 'infrastructure.resourceGroupReadFailed' `
                    -Summary 'The deployment resource group could not be inspected.' `
                    -Expected 'A readable resource group.' `
                    -Remediation 'Confirm Azure resource read access and the selected resource group.'
            }
        }

    New-AzdValidationCheckDefinition -Id 'configuration.protected-accounts' -Phase configuration `
        -Title 'Protected account references are complete' `
        -Summary 'Every expected emergency account has a recorded object ID or UPN.' `
        -SideEffect none `
        -Remediation 'Complete emergency identity provisioning and rerun validation.' `
        -Action {
            $accountNumbers = if ($env:AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT -eq 'true') { 1, 2, 3 } else { 1, 2 }
            $missing = @(
                foreach ($number in $accountNumbers) {
                    if (-not [Environment]::GetEnvironmentVariable("AZD_EMERGENCY_USER${number}_UPN") -and
                        -not [Environment]::GetEnvironmentVariable("AZD_EMERGENCY_USER${number}_ID")) {
                        $number
                    }
                }
            )
            if ($missing.Count -gt 0) {
                return (New-AzdCheckFailure -Code 'configuration.accountReferenceMissing' `
                    -Summary 'One or more protected emergency account references are missing.' `
                    -Expected $accountNumbers.Count -Details @{ missingAccountNumbers = $missing } `
                    -Remediation 'Complete emergency identity provisioning and rerun validation.')
            }
            New-AzdCheckOutcome -Summary "Verified references for $($accountNumbers.Count) protected account(s)." `
                -Expected $accountNumbers.Count -Actual $accountNumbers.Count
        }

    New-AzdValidationCheckDefinition -Id 'configuration.signin-alerts' -Phase configuration `
        -Title 'Azure Monitor sign-in alerting is readable' `
        -Summary 'Enabled Azure Monitor sign-in alert resources are present.' `
        -SideEffect readOnly -DependsOn 'infrastructure.resource-group' `
        -Remediation 'Rerun provisioning or correct the sign-in alert and action-group resources.' `
        -Action {
            if ($env:AZD_ENABLE_SIGNIN_ALERTS -ne 'true') {
                return (New-AzdCheckOutcome -Status info -Summary 'Azure Monitor sign-in alerting is not enabled.')
            }
            $resources = @($env:AZURE_SIGNIN_ALERT_RULE_ID, $env:AZURE_SIGNIN_ALERT_ACTION_GROUP_ID)
            if (@($resources | Where-Object { -not $_ }).Count -gt 0) {
                return (New-AzdCheckFailure -Code 'configuration.signinAlertOutputMissing' `
                    -Summary 'An enabled Azure Monitor sign-in alert output is missing.' `
                    -Expected 'Alert rule and action group resource IDs.' `
                    -Remediation 'Rerun provisioning and inspect the sign-in alert deployment outputs.')
            }
            foreach ($resourceId in $resources) {
                & az resource show --ids $resourceId --only-show-errors --output none
                if ($LASTEXITCODE -ne 0) {
                    return (New-AzdCheckFailure -Code 'configuration.signinAlertReadFailed' `
                        -Summary 'An enabled Azure Monitor sign-in alert resource is unreadable.' `
                        -Expected 'Readable alert rule and action group resources.' `
                        -Remediation 'Confirm Azure access and rerun provisioning or validation.')
                }
            }
            New-AzdCheckOutcome -Summary 'The Azure Monitor sign-in alert and action group are readable.'
        }

    New-AzdValidationCheckDefinition -Id 'configuration.sentinel-resources' -Phase configuration `
        -Title 'Sentinel activity alerting is complete' `
        -Summary 'Enabled Sentinel analytics, automation, role, and playbook resources are readable.' `
        -SideEffect readOnly -DependsOn 'infrastructure.resource-group' `
        -Remediation 'Rerun provisioning and inspect the Sentinel activity alert deployment.' `
        -Action {
            if ($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -ne 'true') {
                return (New-AzdCheckOutcome -Status info -Summary 'Sentinel activity alerting is not enabled.')
            }
            $resources = @(
                @{ Id = $env:AZURE_SENTINEL_SIGNIN_RULE_ID; ApiVersion = '2024-01-01-preview' },
                @{ Id = $env:AZURE_SENTINEL_ADMIN_ACTIVITY_RULE_ID; ApiVersion = '2024-01-01-preview' },
                @{ Id = $env:AZURE_SENTINEL_ACCOUNT_CHANGE_RULE_ID; ApiVersion = '2024-01-01-preview' },
                @{ Id = $env:AZURE_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID; ApiVersion = '2024-09-01' },
                @{ Id = $env:AZURE_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID; ApiVersion = '2022-04-01' },
                @{ Id = $env:AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID; ApiVersion = '2019-05-01' }
            )
            if (@($resources | Where-Object { -not $_.Id }).Count -gt 0) {
                return (New-AzdCheckFailure -Code 'configuration.sentinelOutputMissing' `
                    -Summary 'An enabled Sentinel activity alert output is missing.' `
                    -Expected $resources.Count `
                    -Remediation 'Rerun provisioning and inspect the Sentinel deployment outputs.')
            }
            foreach ($resource in $resources) {
                & az resource show --ids $resource.Id --api-version $resource.ApiVersion `
                    --only-show-errors --output none
                if ($LASTEXITCODE -ne 0) {
                    return (New-AzdCheckFailure -Code 'configuration.sentinelResourceReadFailed' `
                        -Summary 'An enabled Sentinel activity alert resource is unreadable.' `
                        -Expected 'Readable Sentinel analytics, automation, role, and playbook resources.' `
                        -Remediation 'Confirm Azure access and rerun provisioning or validation.')
                }
            }
            New-AzdCheckOutcome -Summary 'Sentinel activity analytics, automation, role, and playbook resources are readable.'
        }

    New-AzdValidationCheckDefinition -Id 'security.sentinel-function-authentication' -Phase security `
        -Title 'Sentinel Function authentication is exact' `
        -Summary 'Easy Auth enforces the expected audience and playbook principal and rejects an unauthenticated request.' `
        -SideEffect negativeProbe -DependsOn 'infrastructure.resource-group' `
        -Remediation 'Correct Easy Auth, audience, or allowed-principal configuration before using Sentinel remediation.' `
        -Action {
            if ($env:AZD_DEPLOYMENT_MODE -ne 'sentinel-function') {
                return (New-AzdCheckOutcome -Status info -Summary 'Sentinel Function mode is not selected.')
            }
            try {
                Test-EmergencySentinelFunctionAuthentication
                New-AzdCheckOutcome -Summary 'Sentinel Function Easy Auth is exact and returned HTTP 401 to the unauthenticated probe.' `
                    -Expected 401 -Actual 401
            }
            catch {
                New-AzdCheckFailure -Code 'security.sentinelFunctionAuthenticationFailed' `
                    -Summary 'Sentinel Function authentication validation failed.' `
                    -Expected 'Exact audience, exact playbook principal, and HTTP 401.' `
                    -Remediation 'Inspect Easy Auth and the Function endpoint before enabling Sentinel remediation.'
            }
        }

    New-AzdValidationCheckDefinition -Id 'configuration.notification-coverage' -Phase configuration `
        -Title 'Emergency-account notification coverage is explicit' `
        -Summary 'At least one emergency-account notification path is enabled.' `
        -SideEffect none `
        -Remediation 'Enable Azure Monitor sign-in alerts or Sentinel activity alerting and validate delivery.' `
        -Action {
            if ($env:AZD_ENABLE_SIGNIN_ALERTS -ne 'true' -and
                $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -ne 'true') {
                return (New-AzdCheckOutcome -Status warning `
                    -Summary 'No emergency-account use notification path is enabled yet.' `
                    -Remediation 'Enable Azure Monitor sign-in alerts or Sentinel activity alerting and validate delivery.')
            }
            New-AzdCheckOutcome -Summary 'At least one emergency-account notification path is enabled.'
        }

    New-AzdValidationCheckDefinition -Id 'delivery.sentinel-notification' -Phase delivery `
        -Title 'Sentinel notification reaches its configured destination' `
        -Summary 'A labeled Sentinel incident payload produced a successful notification playbook run.' `
        -SideEffect syntheticDelivery -DependsOn 'configuration.sentinel-resources' `
        -Remediation 'Inspect the Sentinel playbook connection, run history, and final Teams or email destination.' `
        -Action {
            if ($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -ne 'true') {
                return (New-AzdCheckOutcome -Status skipped -Summary 'Sentinel activity alerting is not enabled.')
            }
            try {
                $verifiedActions = @(Invoke-EmergencySentinelNotificationDelivery `
                        -PlaybookResourceId $env:AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID)
                New-AzdCheckOutcome -Summary 'The Sentinel notification playbook completed every configured delivery action.' `
                    -Evidence @{ verifiedActionNames = $verifiedActions }
            }
            catch {
                New-AzdCheckFailure -Code 'delivery.sentinelNotificationFailed' `
                    -Summary 'The Sentinel notification delivery test failed.' `
                    -Expected 'A successful Logic App run and final destination delivery.' `
                    -Remediation 'Inspect the playbook connection, run history, and final Teams or email destination.'
            }
        }
}

Export-ModuleMember -Function 'Get-ProjectValidationDefinition'
