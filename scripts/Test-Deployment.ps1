[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not $env:AZURE_RESOURCE_GROUP) {
    throw 'AZURE_RESOURCE_GROUP was not provided by the infrastructure deployment.'
}

$resources = & az resource list --resource-group $env:AZURE_RESOURCE_GROUP --query '[].{name:name,type:type}' -o json |
    ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect deployment resource group '$($env:AZURE_RESOURCE_GROUP)'."
}
if (@($resources).Count -eq 0) {
    throw "Deployment resource group '$($env:AZURE_RESOURCE_GROUP)' contains no resources."
}

Write-Host "Verified $(@($resources).Count) resource(s) for mode '$($env:AZD_DEPLOYMENT_MODE)' in '$($env:AZURE_RESOURCE_GROUP)'."

if ($env:AZD_ENABLE_SIGNIN_ALERTS -eq 'true') {
    foreach ($resourceId in $env:AZURE_SIGNIN_ALERT_RULE_ID, $env:AZURE_SIGNIN_ALERT_ACTION_GROUP_ID) {
        if (-not $resourceId) {
            throw 'Azure Monitor sign-in alerting was enabled but an expected resource output is missing.'
        }
        & az resource show --ids $resourceId --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to verify deployed Azure Monitor alert resource '$resourceId'."
        }
    }
    Write-Host 'Verified the Azure Monitor sign-in alert and action group.'
}

function Test-SentinelNotificationDelivery {
    param([Parameter(Mandatory)][string] $PlaybookResourceId)

    $triggerName = 'Microsoft_Sentinel_incident'
    $managementBase = "https://management.azure.com$PlaybookResourceId"
    $callback = & az rest `
        --method post `
        --url "$managementBase/triggers/$triggerName/listCallbackUrl?api-version=2019-05-01" `
        --output json `
        --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $callback.value) {
        throw 'Unable to obtain the Sentinel notification playbook trigger callback for delivery testing.'
    }

    $trackingId = [guid]::NewGuid().ToString()
    $payload = @{
        object = @{
            id = "$PlaybookResourceId/providers/Microsoft.SecurityInsights/incidents/delivery-smoke-test"
            name = 'delivery-smoke-test'
            type = 'Microsoft.SecurityInsights/Incidents'
            properties = @{
                title = '[TEST] Emergency access notification delivery validation'
                description = 'Authorized azd post-deployment smoke test. No emergency account or tenant object was changed.'
                severity = 'Informational'
                status = 'New'
                incidentNumber = 0
                incidentUrl = 'https://portal.azure.com/'
            }
        }
    } | ConvertTo-Json -Depth 8 -Compress

    try {
        $response = Invoke-WebRequest `
            -Method Post `
            -Uri $callback.value `
            -ContentType 'application/json' `
            -Headers @{ 'x-ms-client-tracking-id' = $trackingId } `
            -Body $payload
    }
    catch {
        throw "The Sentinel notification playbook rejected the delivery smoke test. $($_.Exception.Message)"
    }
    if ([int]$response.StatusCode -notin 200, 201, 202) {
        throw "The Sentinel notification playbook returned HTTP $([int]$response.StatusCode) for the delivery smoke test."
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
    $run = $null
    do {
        Start-Sleep -Seconds 3
        $runs = & az rest `
            --method get `
            --url "$managementBase/runs?api-version=2019-05-01" `
            --output json `
            --only-show-errors | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to inspect the Sentinel notification playbook smoke-test run.'
        }
        $run = @($runs.value) |
            Where-Object { $_.properties.correlation.clientTrackingId -eq $trackingId } |
            Select-Object -First 1
    } while ((-not $run -or $run.properties.status -in 'Running', 'Waiting') -and
        [DateTimeOffset]::UtcNow -lt $deadline)

    if (-not $run) {
        throw "No Sentinel notification playbook run with tracking ID '$trackingId' appeared within 60 seconds."
    }
    if ($run.properties.status -ne 'Succeeded') {
        $actions = & az rest `
            --method get `
            --url "$managementBase/runs/$($run.name)/actions?api-version=2019-05-01" `
            --output json `
            --only-show-errors | ConvertFrom-Json
        $failures = @($actions.value) |
            Where-Object { $_.properties.status -eq 'Failed' } |
            ForEach-Object { "$($_.name): $($_.properties.code)" }
        $detail = if ($failures) { " Failed actions: $($failures -join '; ')." } else { '' }
        throw "Sentinel notification delivery smoke test ended with status '$($run.properties.status)'.$detail"
    }

    Write-Host 'Verified live Sentinel notification delivery with a labeled test message.'
}

if ($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -eq 'true') {
    $sentinelResources = @(
        @{ Id = $env:AZURE_SENTINEL_SIGNIN_RULE_ID; ApiVersion = '2024-01-01-preview' },
        @{ Id = $env:AZURE_SENTINEL_ADMIN_ACTIVITY_RULE_ID; ApiVersion = '2024-01-01-preview' },
        @{ Id = $env:AZURE_SENTINEL_ACCOUNT_CHANGE_RULE_ID; ApiVersion = '2024-01-01-preview' },
        @{ Id = $env:AZURE_SENTINEL_NOTIFICATION_AUTOMATION_RULE_ID; ApiVersion = '2024-09-01' },
        @{ Id = $env:AZURE_SENTINEL_ACTIVITY_READER_ROLE_ASSIGNMENT_ID; ApiVersion = '2022-04-01' },
        @{ Id = $env:AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID; ApiVersion = '2019-05-01' }
    )
    foreach ($resource in $sentinelResources) {
        if (-not $resource.Id) {
            throw 'Sentinel activity alerting was enabled but an expected resource output is missing.'
        }
        & az resource show --ids $resource.Id --api-version $resource.ApiVersion --only-show-errors | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to verify deployed Sentinel activity resource '$($resource.Id)'."
        }
    }
    Write-Host 'Verified all three Sentinel activity rules, the automation rule, workspace Reader assignment, and notification playbook.'
    if ($env:AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY -eq 'true') {
        Test-SentinelNotificationDelivery -PlaybookResourceId $env:AZURE_SENTINEL_ACTIVITY_PLAYBOOK_RESOURCE_ID
    }
}

$accountNumbers = if ($env:AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT -eq 'true') { 1, 2, 3 } else { 1, 2 }
$accountReferences = foreach ($number in $accountNumbers) {
    $upn = [Environment]::GetEnvironmentVariable("AZD_EMERGENCY_USER${number}_UPN")
    $id = [Environment]::GetEnvironmentVariable("AZD_EMERGENCY_USER${number}_ID")
    if ($upn) { $upn } else { $id }
}
Write-Host ''
Write-Host 'Emergency access deployment validation completed.'
Write-Host "  Protected accounts: $($accountReferences -join ', ')"
Write-Host "  Conditional Access maintenance: $($env:AZD_DEPLOYMENT_MODE)"
Write-Host "  Azure Monitor sign-in email: $($env:AZD_ENABLE_SIGNIN_ALERTS)"
Write-Host "  Sentinel activity and Teams: $($env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS)"
if ($env:AZD_ENABLE_SIGNIN_ALERTS -ne 'true' -and
    $env:AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS -ne 'true') {
    Write-Warning 'No emergency-account use notification path is enabled yet.'
}
Write-Host 'Next: test each account and recovery device, verify notifications, and record the drill.'
