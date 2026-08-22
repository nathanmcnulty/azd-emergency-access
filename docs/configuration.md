# Configuration reference

[Back to the quickstart](../README.md)

The interactive wizard persists its choices in the current azd environment. Advanced administrators and the future graphical wizard can set the same values before `azd up`; when `AZD_DEPLOYMENT_MODE` is already set, the console wizard is skipped.

## Core settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `AZD_DEPLOYMENT_MODE` | prompted | `function-scheduled`, `automation-scheduled`, `logicapp-scheduled`, or `sentinel-function` |
| `AZURE_LOCATION` | `westus2` | Azure deployment region |
| `AZD_EMERGENCY_DOMAIN` | none | Verified domain used when creating users |
| `AZD_EMERGENCY_USER1_ID`, `AZD_EMERGENCY_USER2_ID` | none | Existing user object IDs |
| `AZD_EMERGENCY_USER1_UPN`, `AZD_EMERGENCY_USER2_UPN` | none | Existing user principal names to resolve |
| `AZD_ENABLE_LIMITED_EMERGENCY_ACCOUNT` | `false` | Add a third account with Conditional Access Administrator and Authentication Policy Administrator |
| `AZD_EMERGENCY_USER3_ID`, `AZD_EMERGENCY_USER3_UPN` | none | Optional limited emergency account reference; otherwise it is created from `AZD_EMERGENCY_DOMAIN` |
| `AZD_EMERGENCY_GROUP_ID` | none | Existing emergency security-group object ID |
| `AZD_ADMINISTRATIVE_UNIT_ID` | none | Existing administrative-unit object ID |
| `AZD_MANAGE_EMERGENCY_IDENTITIES` | `true` | Set `false` to prevent user, group, role, AU, and TAP changes |
| `AZD_USE_RESTRICTED_AU` | `true` | Create or reuse a restricted management administrative unit |
| `AZD_ENABLE_TAP_POLICY` | `false` outside the wizard | Configure TAP and create interactive passes |
| `AZD_AUTHENTICATION_READY` | `false` | Explicit noninteractive confirmation when TAP is skipped for existing managed accounts |
| `AZD_RESOURCE_NAME_PREFIX` | environment-derived | Optional deterministic Azure resource prefix |

## Scheduling

| Variable | Default | Used by |
| --- | --- | --- |
| `AZD_SCHEDULE_CRON` | `0 0 */6 * * *` | Scheduled Function |
| `AZD_SCHEDULE_INTERVAL` | `6` | Automation and scheduled Logic App |
| `AZD_SCHEDULE_FREQUENCY` | `Hour` | Automation and scheduled Logic App |
| `AZD_AUTOMATION_TIME_ZONE` | `Etc/UTC` | Azure Automation |
| `AZD_AUTOMATION_START_TIME` | 15 minutes in the future | Azure Automation; refreshed before first creation when stale |

## Azure Monitor sign-in alerting

| Variable | Purpose |
| --- | --- |
| `AZD_ENABLE_SIGNIN_ALERTS` | Set `true` to deploy the alert and action group |
| `AZD_SIGNIN_LOG_WORKSPACE_NAME` | Existing workspace receiving `SigninLogs` |
| `AZD_SIGNIN_LOG_WORKSPACE_RESOURCE_GROUP` | Workspace resource group |
| `AZD_SIGNIN_LOG_WORKSPACE_SUBSCRIPTION_ID` | Workspace subscription; defaults to the deployment or Sentinel subscription |
| `AZD_SIGNIN_ALERT_EMAIL` | One plain email address |

## Sentinel and Teams

| Variable | Purpose |
| --- | --- |
| `AZD_ENABLE_SENTINEL_ACTIVITY_ALERTS` | Deploy emergency sign-in, activity, and account-change detections |
| `AZD_SENTINEL_WORKSPACE_NAME` | Existing Sentinel workspace |
| `AZD_SENTINEL_WORKSPACE_RESOURCE_GROUP` | Sentinel workspace resource group |
| `AZD_SENTINEL_WORKSPACE_SUBSCRIPTION_ID` | Workspace subscription in the same tenant |
| `AZD_SENTINEL_TEAMS_DELIVERY_MODE` | `admin-configured`, `workflow-webhook`, or `api-connection` |
| `AZD_SENTINEL_TEAMS_CHANNEL_LINK` | Channel link copied from Teams for guided setup |
| `AZD_SENTINEL_TEAMS_WEBHOOK_URL` | Secret callback URL for webhook mode |
| `AZD_SENTINEL_TEAMS_CONNECTION_RESOURCE_ID` | Existing Teams API connection for API-connection mode |
| `AZD_SENTINEL_TEAMS_TEAM_ID`, `AZD_SENTINEL_TEAMS_CHANNEL_ID` | Explicit destination IDs |
| `AZD_TEST_SENTINEL_NOTIFICATION_DELIVERY` | Post and verify one labeled test notification |
| `AZD_SENTINEL_OUTLOOK_CONNECTION_RESOURCE_ID` | Existing Outlook API connection for optional email |
| `AZD_SENTINEL_NOTIFICATION_EMAIL` | Recipient used with the Outlook connection |

Sentinel Function mode also uses hook-managed `AZD_FUNCTION_AUTH_CLIENT_ID` and `AZD_FUNCTION_AUTH_AUDIENCE`. Normally, do not set them manually.

## Existing externally managed identities

```powershell
azd env set AZD_DEPLOYMENT_MODE function-scheduled
azd env set AZD_MANAGE_EMERGENCY_IDENTITIES false
azd env set AZD_EMERGENCY_GROUP_ID 22222222-2222-2222-2222-222222222222
azd env set AZD_EMERGENCY_USER1_ID 11111111-1111-1111-1111-111111111111
azd env set AZD_EMERGENCY_USER2_ID 44444444-4444-4444-4444-444444444444
azd up
```

The user IDs are required when alerting is enabled. The group ID is always required because the remediation workload uses it.

## Preview and noninteractive deployment

The first `azd provision --preview` does not execute project hooks. When object IDs have not yet been resolved, run:

```powershell
azd hooks run preprovision
azd provision --preview
azd up
```

For CI or another controller, set `AZD_NON_INTERACTIVE=true`, set `AZD_DEPLOYMENT_MODE` and every required value, authenticate Azure using workload identity federation, and establish one compatible standard `Connect-MgGraph` delegated context before hooks run. TAP values are never emitted noninteractively.

The graphical wizard should write these same environment values and then invoke the existing azd lifecycle. It should not create a separate deployment contract.
