Set-StrictMode -Version Latest

function Assert-ObjectId {
    param(
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $Value
    )

    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed)) {
        throw "$Name must be a valid Microsoft Entra object ID."
    }
}

function Invoke-ConditionalAccessGraphRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'PATCH')]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Uri,
        [string] $Body
    )

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $parameters = @{
                Method = $Method
                Uri = $Uri
            }
            if ($Body) {
                $parameters.Body = $Body
                $parameters.ContentType = 'application/json'
            }
            return Invoke-MgGraphRequest @parameters
        }
        catch {
            $responseProperty = $_.Exception.PSObject.Properties['Response']
            $response = if ($responseProperty) { $responseProperty.Value } else { $null }
            $statusCode = if ($response -and $response.StatusCode) {
                [int]$response.StatusCode
            }
            elseif ($_.Exception.Message -match 'HTTP\s+(429|503)') {
                [int]$Matches[1]
            }
            else {
                0
            }
            if ($statusCode -notin 429, 503 -or $attempt -eq 4) {
                throw
            }

            $delaySeconds = [math]::Pow(2, $attempt - 1)
            $retryAfter = if ($response -and $response.Headers) { $response.Headers.RetryAfter } else { $null }
            if ($retryAfter -and $retryAfter.Delta) {
                $delaySeconds = [math]::Ceiling($retryAfter.Delta.TotalSeconds)
            }
            elseif ($retryAfter -and $retryAfter.Date) {
                $delaySeconds = [math]::Ceiling(($retryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds)
            }
            $delaySeconds = [math]::Max(1, [math]::Min(30, $delaySeconds))
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Invoke-EmergencyAccessRemediation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $EmergencyAccountsGroupObjectId,
        [string] $CAPolicyId,
        [switch] $SkipManagedIdentityConnection
    )

    Assert-ObjectId -Name 'EmergencyAccountsGroupObjectId' -Value $EmergencyAccountsGroupObjectId
    if ($CAPolicyId) {
        Assert-ObjectId -Name 'CAPolicyId' -Value $CAPolicyId
    }

    if (-not $SkipManagedIdentityConnection) {
        if ($env:MANAGED_IDENTITY_CLIENT_ID) {
            Connect-MgGraph -Identity -ClientId $env:MANAGED_IDENTITY_CLIENT_ID -NoWelcome
        }
        else {
            Connect-MgGraph -Identity -NoWelcome
        }
    }

    $policies = if ($CAPolicyId) {
        @(
            Invoke-ConditionalAccessGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$CAPolicyId"
        )
    }
    else {
        $allPolicies = [System.Collections.Generic.List[object]]::new()
        $nextLink = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
        while ($nextLink) {
            $page = Invoke-ConditionalAccessGraphRequest -Method GET -Uri $nextLink
            foreach ($policy in @($page.value)) {
                $allPolicies.Add($policy)
            }
            $nextLink = if ($page -is [Collections.IDictionary]) {
                [string]$page['@odata.nextLink']
            }
            else {
                $nextLinkProperty = $page.PSObject.Properties['@odata.nextLink']
                if ($nextLinkProperty) { [string]$nextLinkProperty.Value } else { '' }
            }
        }
        @($allPolicies)
    }

    $updated = [System.Collections.Generic.List[string]]::new()
    $unchanged = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()

    foreach ($policy in $policies) {
        $policyId = [string]$policy.id
        $userConditions = $policy.conditions.users
        $includeUsers = if ($userConditions -is [Collections.IDictionary]) {
            @($userConditions['includeUsers'])
        }
        else {
            $includeUsersProperty = $userConditions.PSObject.Properties['includeUsers']
            if ($includeUsersProperty) { @($includeUsersProperty.Value) } else { @() }
        }
        if ('None' -in $includeUsers) {
            $unchanged.Add($policyId)
            continue
        }
        if ($EmergencyAccountsGroupObjectId -in @($userConditions.excludeGroups)) {
            $unchanged.Add($policyId)
            continue
        }
        try {
            $policyUri = "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies/$policyId"
            $freshPolicy = Invoke-ConditionalAccessGraphRequest -Method GET -Uri $policyUri
            $freshUserConditions = $freshPolicy.conditions.users
            $freshIncludeUsers = @($freshUserConditions.includeUsers)
            if ('None' -in $freshIncludeUsers) {
                $unchanged.Add($policyId)
                continue
            }
            $current = @(
                @($freshUserConditions.excludeGroups) |
                    Where-Object { $_ } |
                    ForEach-Object { [string]$_ } |
                    Select-Object -Unique
            )
            if ($EmergencyAccountsGroupObjectId -in $current) {
                $unchanged.Add($policyId)
                continue
            }

            $body = @{
                conditions = @{
                    users = @{
                        excludeGroups = @($current + $EmergencyAccountsGroupObjectId | Select-Object -Unique)
                    }
                }
            } | ConvertTo-Json -Depth 8 -Compress
            Invoke-ConditionalAccessGraphRequest -Method PATCH -Uri $policyUri -Body $body | Out-Null

            $verifiedPolicy = Invoke-ConditionalAccessGraphRequest -Method GET -Uri $policyUri
            if ($EmergencyAccountsGroupObjectId -notin @($verifiedPolicy.conditions.users.excludeGroups)) {
                throw "Conditional Access policy '$policyId' did not contain the emergency group after PATCH."
            }
            $updated.Add($policyId)
        }
        catch {
            $failed.Add([pscustomobject]@{
                policyId = $policyId
                error = $_.Exception.Message
            })
        }
    }

    $result = [pscustomobject][ordered]@{
        mode = if ($CAPolicyId) { 'targeted' } else { 'scheduled' }
        policiesEvaluated = $policies.Count
        policiesUpdated = $updated.Count
        policiesAlreadyExcluded = $unchanged.Count
        policiesFailed = $failed.Count
        updatedPolicyIds = @($updated)
        unchangedPolicyIds = @($unchanged)
        failed = @($failed)
    }

    if ($failed.Count -gt 0) {
        $exception = [InvalidOperationException]::new(
            "Failed to remediate $($failed.Count) Conditional Access policy or policies."
        )
        $exception.Data['Result'] = $result
        throw $exception
    }

    return $result
}

Export-ModuleMember -Function Invoke-EmergencyAccessRemediation
