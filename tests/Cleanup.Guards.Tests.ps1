BeforeAll {
    Import-Module "$PSScriptRoot\..\scripts\Cleanup.Guards.psm1" -Force
}

Describe 'Cleanup ownership guards' {
    It 'accepts only an exact owned object ID' {
        $id = '11111111-1111-1111-1111-111111111111'
        Test-OwnedObjectId -CurrentId $id -OwnedId $id | Should -BeTrue
        Test-OwnedObjectId -CurrentId $id `
            -OwnedId '22222222-2222-2222-2222-222222222222' | Should -BeFalse
        Test-OwnedObjectId -CurrentId $id -OwnedId 'not-a-guid' | Should -BeFalse
        Test-OwnedObjectId -CurrentId 'not-a-guid' -OwnedId $id | Should -BeFalse
    }

    It 'accepts a deterministic Sentinel rule only in the expected workspace' {
        $resourceId = '/subscriptions/sub/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law/providers/Microsoft.SecurityInsights/alertRules/33333333-3333-3333-3333-333333333333'
        Test-OwnedSentinelResourceId -ResourceId $resourceId -SubscriptionId sub `
            -ResourceGroup rg -WorkspaceName law -ResourceType alertRules | Should -BeTrue
        Test-OwnedSentinelResourceId -ResourceId $resourceId -SubscriptionId sub `
            -ResourceGroup other -WorkspaceName law -ResourceType alertRules | Should -BeFalse
        Test-OwnedSentinelResourceId -ResourceId $resourceId -SubscriptionId other `
            -ResourceGroup rg -WorkspaceName law -ResourceType alertRules | Should -BeFalse
        Test-OwnedSentinelResourceId -ResourceId $resourceId -SubscriptionId sub `
            -ResourceGroup rg -WorkspaceName other -ResourceType alertRules | Should -BeFalse
        Test-OwnedSentinelResourceId -ResourceId $resourceId -SubscriptionId sub `
            -ResourceGroup rg -WorkspaceName law -ResourceType automationRules | Should -BeFalse
        Test-OwnedSentinelResourceId -ResourceId ($resourceId -replace '33333333-3333-3333-3333-333333333333', 'not-a-guid') `
            -SubscriptionId sub -ResourceGroup rg -WorkspaceName law `
            -ResourceType alertRules | Should -BeFalse
    }
}
