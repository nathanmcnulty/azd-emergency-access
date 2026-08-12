#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Temporary Access Pass (TAP) enablement helpers for emergency access accounts.

.DESCRIPTION
    Used by scripts/postprovision.ps1 when AZD_ENABLE_TAP_POLICY is 'true' (or the deployer opts in
    interactively). A Temporary Access Pass is used exactly once by an administrator to sign in to a
    break-glass account and immediately register at least two passkeys (FIDO2 security keys) so that
    the account no longer depends on a password at all going forward.

    No TAP value is ever logged, written to a file, persisted to azd environment values, added to a
    Bicep/ARM output, or stored in Key Vault. Graph only ever returns a TAP's secret value once, at
    creation time; this module returns it to the caller in-memory exactly once so the calling script
    can print it directly to the interactive console and then let it fall out of scope.
#>

Set-StrictMode -Version Latest

function Enable-TemporaryAccessPassPolicy {
    <#
    .SYNOPSIS
        Enables the tenant's Temporary Access Pass authentication method policy, scoped to the
        emergency access group only (not "All users").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $GroupId
    )

    $body = @{
        '@odata.type'          = '#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration'
        state                  = 'enabled'
        isUsableOnce           = $false
        minimumLifetimeInMinutes = 60
        maximumLifetimeInMinutes = 480
        defaultLifetimeInMinutes = 120
        defaultLength          = 8
        includeTargets         = @(
            @{
                targetType             = 'group'
                id                     = $GroupId
                isRegistrationRequired = $false
            }
        )
    }

    Invoke-MgGraphRequest -Method PATCH `
        -Uri 'https://graph.microsoft.com/v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/TemporaryAccessPass' `
        -Body ($body | ConvertTo-Json -Depth 6) -ContentType 'application/json' | Out-Null
}

function Test-ActiveTemporaryAccessPass {
    <#
    .SYNOPSIS
        Returns $true if the user already has a non-expired Temporary Access Pass method, since
        Graph never returns a previously-created TAP's secret value again.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $UserId
    )

    $methods = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/users/$UserId/authentication/temporaryAccessPassMethods").value
    $now = [datetime]::UtcNow

    foreach ($method in @($methods)) {
        if (-not $method.startDateTime) { continue }
        $start = [datetime]::Parse($method.startDateTime, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        $end = $start.AddMinutes([int]$method.lifetimeInMinutes)
        if ($now -lt $end) {
            return $true
        }
    }

    return $false
}

function New-ReusableTemporaryAccessPass {
    <#
    .SYNOPSIS
        Creates a reusable (isUsableOnce = $false) Temporary Access Pass valid for exactly 2 hours.

    .OUTPUTS
        The plaintext TAP value as a [string]. The caller is solely responsible for displaying it
        once to an interactive console and must never log, return further, or persist it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $UserId
    )

    $body = @{
        lifetimeInMinutes = 120
        isUsableOnce      = $false
    }

    $created = Invoke-MgGraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/users/$UserId/authentication/temporaryAccessPassMethods" `
        -Body ($body | ConvertTo-Json) -ContentType 'application/json'

    return $created.temporaryAccessPass
}

Export-ModuleMember -Function @(
    'Enable-TemporaryAccessPassPolicy',
    'Test-ActiveTemporaryAccessPass',
    'New-ReusableTemporaryAccessPass'
)
