Describe 'Optional emergency sign-in alerting' {
    BeforeAll {
        $main = Get-Content "$PSScriptRoot\..\infra\main.bicep" -Raw
        $alerting = Get-Content "$PSScriptRoot\..\infra\modules\signin-alerting.bicep" -Raw
        $validate = Get-Content "$PSScriptRoot\..\scripts\Validate-Environment.ps1" -Raw
        $parameters = Get-Content "$PSScriptRoot\..\infra\main.parameters.json" -Raw
    }

    It 'is opt-in and passes both resolved user IDs to the alert query' {
        $main | Should -Match "param enableSignInAlerts string = 'false'"
        $main | Should -Match "module signInAlerting .* = if \(enableSignInAlerts == 'true'\)"
        $parameters | Should -Match 'AZD_EMERGENCY_USER1_ID='
        $parameters | Should -Match 'AZD_EMERGENCY_USER2_ID='
        $alerting | Should -Match '@minLength\(1\)\s*param emergencyUser1ObjectId string'
        $alerting | Should -Match '@minLength\(1\)\s*param emergencyUser2ObjectId string'
    }

    It 'alerts on every successful or failed sign-in record for the emergency users' {
        $alerting | Should -Match "SigninLogs"
        $alerting | Should -Match 'UserId in~'
        $alerting | Should -Match 'ingestion_time\(\) >= ago\(5m\)'
        $alerting | Should -Not -Match 'ResultType\s*=='
        $alerting | Should -Match "severity: 0"
        $alerting | Should -Match "autoMitigate: false"
        $alerting | Should -Match "evaluationFrequency: 'PT5M'"
        $alerting | Should -Match "overrideQueryTimeRange: 'PT1H'"
        $alerting | Should -Match "skipQueryValidation: false"
    }

    It 'requires a verified workspace and one plain notification email when enabled' {
        $validate | Should -Match "AZD_ENABLE_SIGNIN_ALERTS -eq 'true'"
        $validate | Should -Match 'AZD_SIGNIN_LOG_WORKSPACE_NAME'
        $validate | Should -Match 'AZD_SIGNIN_ALERT_EMAIL must contain one plain email address'
        $validate | Should -Match 'az resource show --ids \$signInWorkspaceId'
    }
}
