function Test-OwnedObjectId {
    param(
        [string] $CurrentId,
        [string] $OwnedId
    )

    $current = [guid]::Empty
    $owned = [guid]::Empty
    return (
        [guid]::TryParse($CurrentId, [ref]$current) -and
        [guid]::TryParse($OwnedId, [ref]$owned) -and
        $current -eq $owned
    )
}

function Test-OwnedSentinelResourceId {
    param(
        [Parameter(Mandatory)][string] $ResourceId,
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $WorkspaceName,
        [Parameter(Mandatory)]
        [ValidateSet('alertRules', 'automationRules')]
        [string] $ResourceType
    )

    $prefix = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/providers/Microsoft.SecurityInsights/$ResourceType/"
    if (-not $ResourceId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    $leaf = $ResourceId.Substring($prefix.Length)
    $parsed = [guid]::Empty
    return -not $leaf.Contains('/') -and [guid]::TryParse($leaf, [ref]$parsed)
}

function Test-OwnedWorkspaceRoleAssignmentId {
    param(
        [string] $ResourceId,
        [string] $SubscriptionId,
        [string] $ResourceGroup,
        [string] $WorkspaceName
    )

    $escapedPrefix = [regex]::Escape(
        "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName/providers/Microsoft.Authorization/roleAssignments/"
    )
    return $ResourceId -match "(?i)^$escapedPrefix[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
}

Export-ModuleMember -Function Test-OwnedObjectId, Test-OwnedSentinelResourceId, Test-OwnedWorkspaceRoleAssignmentId

