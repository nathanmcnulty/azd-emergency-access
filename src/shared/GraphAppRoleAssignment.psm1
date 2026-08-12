#Requires -Modules Microsoft.Graph.Authentication

<#
.SYNOPSIS
    Shared helper to idempotently grant Microsoft Graph application permissions (app roles) to a
    workload managed identity's service principal.

.DESCRIPTION
    Used by scripts/postprovision.ps1 to grant Policy.Read.All and Policy.ReadWrite.ConditionalAccess
    to whichever managed identity performs remediation for the selected AZD_DEPLOYMENT_MODE
    (Automation account, Function app, or scheduled/playbook Logic App). Existing assignments are
    detected and skipped so re-running postprovision never creates duplicate app role assignments.
#>

Set-StrictMode -Version Latest

$script:GraphResourceAppId = '00000003-0000-0000-c000-000000000000'

function Grant-GraphAppRoleAssignment {
    <#
    .SYNOPSIS
        Idempotently assigns one or more Microsoft Graph application app roles to a service
        principal (typically a managed identity).

    .PARAMETER PrincipalId
        Object ID of the service principal (managed identity) that should receive the app roles.

    .PARAMETER AppRoleValue
        One or more Microsoft Graph app role "value" names, e.g. Policy.Read.All.

    .OUTPUTS
        [pscustomobject[]] one entry per requested role describing whether it was newly granted,
        already present, or failed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $PrincipalId,

        [Parameter(Mandatory = $true)]
        [string[]] $AppRoleValue
    )

    $results = [System.Collections.Generic.List[object]]::new()

    try {
        $graphSp = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$script:GraphResourceAppId')?`$select=id,appRoles"

        $existingAssignments = (Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments").value
    }
    catch {
        foreach ($roleValue in $AppRoleValue) {
            $results.Add([pscustomobject]@{
                appRole = $roleValue
                status  = 'failed'
                error   = $_.Exception.Message
            })
        }
        return $results.ToArray()
    }

    foreach ($roleValue in $AppRoleValue) {
        $appRole = $graphSp.appRoles | Where-Object {
            $_.value -eq $roleValue -and $_.allowedMemberTypes -contains 'Application'
        } | Select-Object -First 1

        if (-not $appRole) {
            $results.Add([pscustomobject]@{
                appRole = $roleValue
                status  = 'failed'
                error   = "App role '$roleValue' was not found on the Microsoft Graph service principal."
            })
            continue
        }

        $alreadyAssigned = $existingAssignments | Where-Object {
            $_.appRoleId -eq $appRole.id -and $_.resourceId -eq $graphSp.id
        }

        if ($alreadyAssigned) {
            $results.Add([pscustomobject]@{
                appRole = $roleValue
                status  = 'already-assigned'
            })
            continue
        }

        try {
            $body = @{
                principalId = $PrincipalId
                resourceId  = $graphSp.id
                appRoleId   = $appRole.id
            }

            Invoke-MgGraphRequest -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments" `
                -Body ($body | ConvertTo-Json) `
                -ContentType 'application/json' | Out-Null

            $results.Add([pscustomobject]@{
                appRole = $roleValue
                status  = 'granted'
            })
        }
        catch {
            $results.Add([pscustomobject]@{
                appRole = $roleValue
                status  = 'failed'
                error   = $_.Exception.Message
            })
        }
    }

    return $results.ToArray()
}

Export-ModuleMember -Function @('Grant-GraphAppRoleAssignment') -Variable @()
