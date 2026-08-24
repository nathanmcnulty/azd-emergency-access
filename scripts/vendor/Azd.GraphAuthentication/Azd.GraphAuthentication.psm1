Set-StrictMode -Version Latest

function Resolve-AzdGraphScopeSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Scope
    )

    $unique = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($entry in $Scope) {
        $normalized = if ($null -eq $entry) { '' } else { $entry.Trim() }
        if ($normalized -notmatch '^[A-Za-z][A-Za-z0-9._-]{0,255}$') {
            throw 'Microsoft Graph scopes must be nonempty permission names without whitespace.'
        }
        if (-not $unique.ContainsKey($normalized)) {
            $unique[$normalized] = $normalized
        }
    }
    if ($unique.Count -eq 0) {
        throw 'At least one Microsoft Graph scope is required.'
    }
    return @($unique.Values | Sort-Object)
}

function Get-AzdGraphContextAssessment {
    param(
        [AllowNull()][object] $Context,
        [Parameter(Mandatory)][guid] $TenantId,
        [Parameter(Mandatory)][string] $Environment,
        [Parameter(Mandatory)][string] $ExpectedAccount,
        [Parameter(Mandatory)][string[]] $Scopes
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $missingScopes = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Context) {
        $reasons.Add('no Microsoft Graph context is available')
    }
    else {
        if ([string] $Context.TenantId -ine $TenantId.Guid) {
            $reasons.Add('the context tenant does not match')
        }
        if ([string] $Context.Environment -ine $Environment) {
            $reasons.Add('the context environment does not match')
        }
        if ([string] $Context.AuthType -ine 'Delegated') {
            $reasons.Add('the context is not delegated')
        }
        if ([string] $Context.ContextScope -ine 'CurrentUser') {
            $reasons.Add('the context is not persisted for the current user')
        }
        if ([string]::IsNullOrWhiteSpace([string] $Context.Account)) {
            $reasons.Add('the context has no selected account')
        }
        elseif ($ExpectedAccount -and [string] $Context.Account -ine $ExpectedAccount) {
            $reasons.Add('the context account does not match')
        }
        foreach ($scope in $Scopes) {
            if ($scope -notin @($Context.Scopes)) {
                $missingScopes.Add($scope)
            }
        }
        if ($missingScopes.Count -gt 0) {
            $reasons.Add("the context is missing scopes: $($missingScopes -join ', ')")
        }
    }

    return [pscustomobject]@{
        IsUsable = $reasons.Count -eq 0
        Reasons = @($reasons)
        MissingScopes = @($missingScopes)
    }
}

function Test-AzdGraphProbe {
    param([Parameter(Mandatory)][string] $ProbeUri)

    try {
        Invoke-MgGraphRequest -Method GET -Uri $ProbeUri -OutputType PSObject -ErrorAction Stop | Out-Null
        return [pscustomobject]@{ Succeeded = $true; ErrorType = $null }
    }
    catch {
        $statusCode = $null
        foreach ($propertyName in 'ResponseStatusCode', 'StatusCode') {
            if ($_.Exception.PSObject.Properties.Name -contains $propertyName) {
                $statusCode = $_.Exception.$propertyName
                break
            }
        }
        if ($null -eq $statusCode -and $_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            foreach ($propertyName in 'StatusCode', 'Status') {
                if ($_.Exception.Response.PSObject.Properties.Name -contains $propertyName) {
                    $statusCode = $_.Exception.Response.$propertyName
                    break
                }
            }
        }
        $numericStatus = if ($null -ne $statusCode) {
            try { [int] $statusCode } catch { $null }
        }
        else { $null }
        $errorType = $_.Exception.GetType().FullName
        $classification = if ($null -ne $numericStatus) {
            if ($numericStatus -eq 401) { 'authentication' }
            elseif ($numericStatus -eq 403) { 'authorization' }
            elseif ($numericStatus -eq 429) { 'throttled' }
            elseif ($numericStatus -ge 500) { 'provider' }
            else { 'request' }
        }
        elseif ($errorType -match '(?i)(MsalUiRequired|AuthenticationRequired)') {
            'authentication'
        }
        else { 'transport' }
        return [pscustomobject]@{
            Succeeded = $false
            Classification = $classification
            StatusCode = $numericStatus
            ErrorType = $errorType
        }
    }
}

function New-AzdGraphSessionResult {
    param(
        [Parameter(Mandatory)][object] $Context,
        [Parameter(Mandatory)][string[]] $Scopes,
        [Parameter(Mandatory)][bool] $ConnectInvoked,
        [Parameter(Mandatory)][bool] $ContextReused
    )

    return [pscustomobject] [ordered]@{
        tenantId = [string] $Context.TenantId
        environment = [string] $Context.Environment
        account = [string] $Context.Account
        authType = [string] $Context.AuthType
        contextScope = [string] $Context.ContextScope
        grantedScopes = @($Scopes)
        connectInvoked = $ConnectInvoked
        contextReused = $ContextReused
        probeSucceeded = $true
    }
}

function Connect-AzdGraphSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid] $TenantId,

        [Parameter(Mandatory)]
        [string[]] $Scopes,

        [Parameter(Mandatory)]
        [string] $ProbeUri,

        [string] $Environment = 'Global',

        [Parameter(Mandatory)]
        [string] $ExpectedAccount,

        [switch] $AllowInteractive,

        [switch] $AllowContextReplacement,

        [ValidateRange(60, 900)]
        [int] $ClientTimeoutSeconds = 300
    )

    $expectedAccountName = $ExpectedAccount.Trim()
    if ($expectedAccountName -notmatch '^[^@\s]+@[^@\s]+$') {
        throw 'ExpectedAccount must be a nonempty user principal name.'
    }
    if ($ProbeUri -notmatch '^/(v1\.0|beta)/(?!/)[^\u0000-\u001F]+$' -or
        -not [System.Uri]::IsWellFormedUriString($ProbeUri, [System.UriKind]::Relative)) {
        throw 'ProbeUri must be a well-formed relative Microsoft Graph v1.0 or beta URI without control characters.'
    }
    $requiredScopes = @(Resolve-AzdGraphScopeSet -Scope $Scopes)
    $environments = @(Get-MgEnvironment | Where-Object Name -IEQ $Environment)
    if ($environments.Count -ne 1) {
        throw "Microsoft Graph environment '$Environment' is not available in the installed authentication module."
    }
    $environmentName = [string] $environments[0].Name
    $context = Get-MgContext
    $assessment = Get-AzdGraphContextAssessment `
        -Context $context `
        -TenantId $TenantId `
        -Environment $environmentName `
        -ExpectedAccount $expectedAccountName `
        -Scopes $requiredScopes

    if ($assessment.IsUsable) {
        $probe = Test-AzdGraphProbe -ProbeUri $ProbeUri
        if ($probe.Succeeded) {
            return New-AzdGraphSessionResult `
                -Context $context `
                -Scopes $requiredScopes `
                -ConnectInvoked $false `
                -ContextReused $true
        }
        if ($probe.Classification -ne 'authentication') {
            throw "The Microsoft Graph read-only probe failed without an authentication error. Authentication was not started. Classification: $($probe.Classification); error type: $($probe.ErrorType)."
        }
        if (-not $AllowInteractive) {
            throw "The matching Microsoft Graph context is not usable in this process. Rerun from an interactive desktop session. Probe error type: $($probe.ErrorType)."
        }
    }
    elseif ($null -ne $context -and -not $AllowContextReplacement) {
        throw "The existing Microsoft Graph context cannot be replaced without explicit authorization: $($assessment.Reasons -join '; ')."
    }
    elseif (-not $AllowInteractive) {
        throw "A usable Microsoft Graph context is required for noninteractive execution: $($assessment.Reasons -join '; ')."
    }

    if (-not $AllowInteractive) {
        throw 'Interactive Microsoft Graph authentication was not authorized.'
    }

    $connectParameters = @{
        TenantId = $TenantId.Guid
        Environment = $environmentName
        Scopes = $requiredScopes
        ContextScope = 'CurrentUser'
        ClientTimeout = $ClientTimeoutSeconds
        NoWelcome = $true
        ErrorAction = 'Stop'
    }
    try {
        Connect-MgGraph @connectParameters | Out-Null
    }
    catch {
        throw "Interactive Microsoft Graph authentication through the normal broker or browser flow failed. No alternate authentication flow was started. Error type: $($_.Exception.GetType().FullName)."
    }

    $context = Get-MgContext
    $assessment = Get-AzdGraphContextAssessment `
        -Context $context `
        -TenantId $TenantId `
        -Environment $environmentName `
        -ExpectedAccount $expectedAccountName `
        -Scopes $requiredScopes
    if (-not $assessment.IsUsable) {
        throw "Microsoft Graph authentication completed without the required session properties: $($assessment.Reasons -join '; ')."
    }

    $probe = Test-AzdGraphProbe -ProbeUri $ProbeUri
    if (-not $probe.Succeeded) {
        throw "Microsoft Graph authentication completed, but the read-only session probe failed. Probe error type: $($probe.ErrorType)."
    }
    return New-AzdGraphSessionResult `
        -Context $context `
        -Scopes $requiredScopes `
        -ConnectInvoked $true `
        -ContextReused $false
}

Export-ModuleMember -Function @(
    'Connect-AzdGraphSession',
    'Resolve-AzdGraphScopeSet'
)
