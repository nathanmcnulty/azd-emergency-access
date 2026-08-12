# azd-emergency-access

An [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/overview) template
that keeps a Microsoft Entra **emergency access ("break-glass") security group** permanently excluded from
Conditional Access policies, using one of four selectable, mutually exclusive remediation mechanisms. It also
provisions (or reuses) the emergency access tenant objects themselves -- two cloud-only Global Administrator
accounts, a security group, and a restricted management administrative unit -- and optionally configures
reusable 2-hour Temporary Access Passes for initial passkey registration.

> **This template intentionally never uses Azure Key Vault and never uses Azure Monitor scheduled query alert
> rules.** See [Future work](#future-work-not-implemented) for the Azure Monitor alerting TODO.

```
azd init --template nathanmcnulty/azd-emergency-access
azd up
```

## Table of contents

- [What this template protects against](#what-this-template-protects-against)
- [Deployment modes](#deployment-modes)
- [Prerequisites](#prerequisites)
- [Deployer permissions](#deployer-permissions)
- [Quickstart](#quickstart)
- [Environment variable reference](#environment-variable-reference)
- [Architecture and data flow per mode](#architecture-and-data-flow-per-mode)
- [Existing vs. created identities](#existing-vs-created-identities)
- [Tenant bootstrap: users, group, restricted AU](#tenant-bootstrap-users-group-restricted-au)
- [Temporary Access Pass and passkeys](#temporary-access-pass-and-passkeys)
- [Microsoft Sentinel prerequisites](#microsoft-sentinel-prerequisites)
- [Security model](#security-model)
- [Verification](#verification)
- [Cleanup](#cleanup)
- [Future work (not implemented)](#future-work-not-implemented)
- [Repository layout](#repository-layout)
- [References](#references)

## What this template protects against

Every Conditional Access policy in a tenant should exclude the emergency access ("break-glass") accounts, so
that a policy misconfiguration, a compromised admin session, or a Conditional Access outage never locks out
the accounts that must be able to sign in when everything else fails. Excluding an entire **security group**
(rather than individual users) is the recommended pattern because it survives account rotation and lets a
single remediation loop protect both current and future break-glass accounts.

This template runs a small PowerShell remediation routine, on the schedule/trigger appropriate to the mode you
pick, that:

1. Reads Conditional Access policies from Microsoft Graph (`GET /v1.0/identity/conditionalAccess/policies`, or
   a single policy by ID in Sentinel mode).
2. For each policy, reads `conditions.users.excludeGroups` **without discarding any existing entries**.
3. If the emergency access group's object ID is **not already present**, appends it (uniquely) to the list.
4. Sends a **minimal PATCH** containing only `{ "conditions": { "users": { "excludeGroups": [...] } } }` -- it
   never touches any other property of the policy.
5. Returns a structured result: which policies were evaluated, which were updated, which were already
   compliant, and which failed (with the Graph error attached), so every mode's caller can log/alert
   consistently.

The logic lives in exactly one place, [`src/shared/EmergencyAccessRemediation.psm1`](src/shared/EmergencyAccessRemediation.psm1),
and is reused unmodified by the Automation runbook, both Function triggers, and the Pester test suite.

## Deployment modes

Set **exactly one** `AZD_DEPLOYMENT_MODE` value per `azd` environment. `scripts/preprovision.ps1` enforces this
and will prompt for a value (interactive) or fail with the exact command to set it (non-interactive/CI).

| `AZD_DEPLOYMENT_MODE`   | Mechanism                                             | Trigger                          | Policies remediated per run | Extra prerequisites |
|-------------------------|--------------------------------------------------------|-----------------------------------|------------------------------|----------------------|
| `automation-scheduled`  | Azure Automation account, system-assigned managed identity, PowerShell runbook | Hourly (configurable) schedule | All Conditional Access policies | None |
| `function-scheduled`    | Azure Functions (PowerShell 7.4, Flex Consumption FC1), user-assigned managed identity | Timer trigger (configurable cron) | All Conditional Access policies | None |
| `logicapp-scheduled`    | Consumption Logic App, system-assigned managed identity | Recurrence trigger (configurable interval) | All Conditional Access policies | None |
| `sentinel-function`     | Microsoft Sentinel NRT analytics rule + automation rule + alert-triggered Consumption Logic App playbook, invoking an Entra-protected Azure Functions HTTP trigger | Near-real-time, only when a CA policy is actually changed | Only the single policy identified in the triggering event (`CAPolicyId`) | An **existing** Sentinel-enabled Log Analytics workspace |

`automation-scheduled`, `function-scheduled`, and `logicapp-scheduled` are **preventive/self-healing**: they
sweep every Conditional Access policy on a timer, independent of whether anything actually changed.
`sentinel-function` is **reactive**: it only acts when Sentinel detects that someone added or updated a
Conditional Access policy, and only remediates that specific policy, which is far cheaper at scale and gives
near-instant remediation instead of waiting for the next scheduled sweep.

## Prerequisites

- [Azure Developer CLI (`azd`)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd) v1.10+
- [Azure CLI (`az`)](https://learn.microsoft.com/cli/azure/install-azure-cli), logged in (`az login`) with access
  to the target subscription
- [PowerShell 7.4+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (the hooks
  and all source use PowerShell, not Bash)
- An Azure subscription with `Microsoft.Automation`, `Microsoft.Web`, `Microsoft.Insights`,
  `Microsoft.OperationalInsights`, `Microsoft.ManagedIdentity`, `Microsoft.Storage`, and
  `Microsoft.Logic` resource providers registered
- For `sentinel-function` mode: an **existing** Log Analytics workspace with Microsoft Sentinel already enabled
- No Key Vault, and no Azure Monitor scheduled query alert rules are used or required by this template

## Deployer permissions

The person (or service principal) running `azd up` / `azd provision` needs:

- **Azure RBAC**: `Contributor` (or `Owner`) on the target subscription or resource group, to create the
  resource group and all mode-specific resources, plus enough RBAC to assign the
  **Microsoft Sentinel Automation Contributor** role at the playbook's resource group (`sentinel-function`
  mode only -- see [Sentinel prerequisites](#microsoft-sentinel-prerequisites) for the fallback if this is
  not delegated).
- **Microsoft Entra ID / Microsoft Graph** (used by `scripts/preprovision.ps1` and `scripts/postprovision.ps1`,
  interactively via `Connect-MgGraph` or non-interactively via an app registration's client credentials):
  - `Application.ReadWrite.All` -- to idempotently create the Easy Auth app registration (`sentinel-function`
    mode) and to grant `Policy.Read.All` / `Policy.ReadWrite.ConditionalAccess` app roles to the workload
    identity.
  - `AppRoleAssignment.ReadWrite.All` -- to grant the app roles above.
  - `User.ReadWrite.All`, `Group.ReadWrite.All`, `AdministrativeUnit.ReadWrite.All` -- for the tenant bootstrap
    (create/reuse the two emergency access users, the security group, and the restricted administrative unit).
  - `RoleManagement.ReadWrite.Directory` -- to assign the (tenant-wide, permanent) Global Administrator role to
    both emergency access users.
  - `Policy.ReadWrite.AuthenticationMethod` -- only if `AZD_ENABLE_TAP_POLICY=true`, to enable/scope the
    Temporary Access Pass authentication method policy.
  - `UserAuthenticationMethod.ReadWrite.All` -- only if Temporary Access Pass creation is requested, to create
    the reusable 2-hour TAPs.

  In practice this means the deployer should typically be a **Global Administrator** or hold an equivalent
  combination of Entra roles (Application Administrator, Privileged Role Administrator, Groups Administrator,
  Privileged Authentication Administrator) -- because this template's entire purpose is to create/maintain
  permanent Global Administrator break-glass accounts, a lesser-privileged identity cannot complete that step.

## Quickstart

```powershell
azd init --template nathanmcnulty/azd-emergency-access
azd env set AZD_DEPLOYMENT_MODE function-scheduled   # or automation-scheduled / logicapp-scheduled / sentinel-function
azd up
```

`azd up` runs, in order: `preprovision` (validates/defaults env vars, prompts interactively for anything
required and missing) -> `provision` (deploys `infra/main.bicep`) -> `postprovision` (tenant bootstrap, Graph
app-role grants, resource configuration patching, and runtime content publishing) -> deploy (a no-op for this
template; see [`azure.yaml`](azure.yaml)).

Re-running `azd up` / `azd provision` at any time is safe: every script is idempotent and reuses whatever
already exists (resources, users, group, AU, role assignments, app roles).

## Environment variable reference

Set with `azd env set <NAME> <VALUE>`. Names in *italics* are read-only outputs set by `azd`/Bicep, not by you.

| Variable | Applies to | Default | Description |
|---|---|---|---|
| `AZD_DEPLOYMENT_MODE` | all | *(required, prompted)* | One of `automation-scheduled`, `function-scheduled`, `logicapp-scheduled`, `sentinel-function`. |
| *`AZD_DEPLOYMENT_MODE_LOCK`* | all | *(set by preprovision)* | Prevents changing modes in an existing environment, which could leave old scheduled resources or external Sentinel content active. Use a separate environment per mode. |
| `AZURE_LOCATION` | all | `eastus2` | Azure region. `westeurope`/`francecentral` trigger a soft warning (some tenants restrict CA/automation identities or Flex Consumption via Azure Policy there); use `eastus2` if unsure. |
| `AZURE_RESOURCE_GROUP` | all | `rg-<AZURE_ENV_NAME>` | Name of the resource group `azd` creates for this environment's resources. |
| `EMERGENCY_ACCESS_GROUP_ID` | all | *(empty; resolved by postprovision)* | Object ID of the emergency access security group. Leave blank to have `postprovision.ps1` create/reuse it; set explicitly to reuse a specific existing group without running tenant bootstrap. |
| `EMERGENCY_ACCESS_USER1_ID` / `EMERGENCY_ACCESS_USER1_UPN` | all | empty | Existing user object ID or UPN to reuse as break-glass account #1. Leave both blank to create a new user. |
| `EMERGENCY_ACCESS_USER2_ID` / `EMERGENCY_ACCESS_USER2_UPN` | all | empty | Same, for break-glass account #2. |
| `EMERGENCY_ACCESS_AU_ID` | all | empty | Existing restricted administrative unit object ID to reuse. Leave blank to create/reuse one named after `EMERGENCY_ACCESS_USER_PREFIX`. |
| `EMERGENCY_ACCESS_USER_PREFIX` | all | `emergency-access` | UPN/display-name/group/AU naming prefix used only when creating new objects. |
| `AZD_SKIP_TENANT_BOOTSTRAP` | all | `false` | Set `true` to skip user/group/AU creation entirely (for example, if you already manage break-glass accounts elsewhere and only want the remediation resources). Requires `EMERGENCY_ACCESS_GROUP_ID` to be set explicitly. |
| `AZD_SKIP_RESTRICTED_AU` | all | `false` | Set `true` to create/reuse the users and group but skip restricted management administrative-unit creation and membership changes. |
| `AZD_ENABLE_TAP_POLICY` | all | `false` | `true` enables/configures the tenant's Temporary Access Pass authentication method policy (scoped to the emergency access group) and creates reusable 2-hour TAPs for both users. `false` in an interactive session prompts you to opt in at postprovision time; `false` non-interactively skips TAP entirely. |
| `AUTOMATION_RECURRENCE_HOURS` | `automation-scheduled` | `1` | Runbook schedule recurrence, in hours. |
| `REMEDIATION_SCHEDULE_CRON` | `function-scheduled` | `0 */15 * * * *` | NCronTab schedule for the timer-triggered function (6-field: second minute hour day month day-of-week). |
| `LOGICAPP_RECURRENCE_MINUTES` | `logicapp-scheduled` | `15` | Recurrence interval, in minutes, for the Consumption Logic App. |
| `SENTINEL_WORKSPACE_NAME` | `sentinel-function` | *(required, prompted)* | Name of the **existing** Sentinel-enabled Log Analytics workspace. |
| `SENTINEL_WORKSPACE_RESOURCE_GROUP` | `sentinel-function` | *(required, prompted)* | Resource group containing that workspace. |
| `SENTINEL_WORKSPACE_SUBSCRIPTION_ID` | `sentinel-function` | current subscription | Subscription containing that workspace, if different from the one you are deploying into. |
| *`SENTINEL_AUTOMATION_PRINCIPAL_ID`* | `sentinel-function` | *(set by preprovision)* | Object ID of the Azure Security Insights service principal. Bicep grants it Microsoft Sentinel Automation Contributor on the playbook resource group before creating the automation rule; postprovision retries if lookup was unavailable. |
| *`FUNCTION_AAD_CLIENT_ID`* | `sentinel-function` | *(set by preprovision)* | App (client) ID of the Entra app registration created to protect the Function's HTTP trigger with Easy Auth V2. |
| *`RESOURCE_GROUP_NAME`*, *`FUNCTION_APP_NAME`*, *`FUNCTION_APP_DEFAULT_HOSTNAME`*, *`FUNCTION_APP_IDENTITY_PRINCIPAL_ID`*, *`FUNCTION_APP_IDENTITY_CLIENT_ID`*, *`AUTOMATION_ACCOUNT_NAME`*, *`AUTOMATION_ACCOUNT_PRINCIPAL_ID`*, *`LOGIC_APP_SCHEDULED_NAME`*, *`LOGIC_APP_SCHEDULED_PRINCIPAL_ID`*, *`SENTINEL_PLAYBOOK_NAME`*, *`SENTINEL_PLAYBOOK_PRINCIPAL_ID`*, *`SENTINEL_ANALYTICS_RULE_ID`* | all (mode-dependent) | — | Non-secret outputs from `infra/main.bicep`, automatically exposed as azd environment values after `azd provision`. Consumed by `scripts/postprovision.ps1`; useful for your own verification/automation too. |

### Examples

```powershell
# Function-scheduled, every 5 minutes, reusing an existing break-glass group:
azd env set AZD_DEPLOYMENT_MODE function-scheduled
azd env set REMEDIATION_SCHEDULE_CRON "0 */5 * * * *"
azd env set EMERGENCY_ACCESS_GROUP_ID 00000000-0000-0000-0000-000000000000
azd env set AZD_SKIP_TENANT_BOOTSTRAP true
azd up

# Sentinel reactive remediation against an existing SOC workspace, with TAP enabled:
azd env set AZD_DEPLOYMENT_MODE sentinel-function
azd env set SENTINEL_WORKSPACE_NAME log-soc-prod
azd env set SENTINEL_WORKSPACE_RESOURCE_GROUP rg-soc-prod
azd env set AZD_ENABLE_TAP_POLICY true
azd up
```

## Architecture and data flow per mode

### `automation-scheduled`

```
Azure Automation Account (system-assigned managed identity)
  -> Schedule (hourly, configurable) -> Job -> Runbook (PowerShell)
    -> imports Microsoft.Graph.Authentication, Connect-MgGraph -Identity
    -> src/shared/EmergencyAccessRemediation.psm1: enumerate ALL CA policies, patch missing exclusions
```

### `function-scheduled`

```
Azure Functions (PowerShell 7.4, Functions v4, Flex Consumption FC1)
  user-assigned managed identity, identity-based storage (no keys)
  -> Timer trigger (RemediateCAPolicies, configurable cron)
    -> src/shared/EmergencyAccessRemediation.psm1: enumerate ALL CA policies, patch missing exclusions
```

### `logicapp-scheduled`

```
Consumption Logic App (system-assigned managed identity)
  -> Recurrence trigger (configurable interval)
    -> HTTP action (Graph GET, managed identity auth) -> policies
    -> For-each -> HTTP action (Graph PATCH, managed identity auth) for any policy missing the exclusion
```

### `sentinel-function`

```
Microsoft Entra Conditional Access policy add/update
  -> Entra Audit Log ("Add/Update conditional access policy")
    -> ingested into the EXISTING Sentinel-enabled Log Analytics workspace
      -> NRT analytics rule (see query below) extracts CAPolicyId, excludes changes made by the
         remediation identity itself (no feedback loop)
        -> Sentinel incident-free alert -> alert-created automation rule
          -> runs the alert-triggered Consumption Logic App playbook (system-assigned managed identity)
            -> HTTP POST (Entra ID auth, playbook's managed identity as caller) to the protected
               Function HTTP trigger, forwarding CAPolicyId
              -> Azure Functions HTTP trigger (Easy Auth V2, allows ONLY the playbook's principal ID)
                -> src/shared/EmergencyAccessRemediation.psm1: remediate ONLY that one CAPolicyId
```

The exact NRT rule query (see [`infra/modules/sentinelContent.bicep`](infra/modules/sentinelContent.bicep)):

```kql
AuditLogs
| where Result =~ "success"
| where OperationName in ("Add conditional access policy", "Update conditional access policy")
| where Identity != "<remediation identity display name>"
| extend CAPolicyId = tostring(todynamic(TargetResources)[0].id), ActorIdentity = Identity
| where isnotempty(CAPolicyId)
| project TimeGenerated, CAPolicyId, OperationName, ActorIdentity, CorrelationId
```

The rule creates **alerts only, no incidents** (`createIncident: false`) -- the point is machine remediation,
not analyst triage. `Identity != "<remediation identity>"` prevents the remediation loop from re-triggering
itself. An **alert-created automation rule** (Sentinel's `Microsoft.SecurityInsights/automationRules` API)
invokes the playbook -- this is the current supported mechanism; it is *not* the deprecated pattern of linking a
playbook directly to the analytics rule.

## Existing vs. created identities

Every workload identity in this template is created fresh by `infra/main.bicep` -- **nothing pre-existing is
required** for the compute/identity side:

| Mode | Identity type | Created by |
|---|---|---|
| `automation-scheduled` | System-assigned managed identity on the Automation Account | `infra/modules/automation.bicep` |
| `function-scheduled` / `sentinel-function` | User-assigned managed identity, shared by the Function App and identity-based storage | `infra/modules/identity.bicep` |
| `logicapp-scheduled` | System-assigned managed identity on the scheduled Logic App | `infra/modules/logicAppScheduled.bicep` |
| `sentinel-function` (playbook) | System-assigned managed identity on the alert-triggered playbook Logic App | `infra/modules/sentinelPlaybook.bicep` |

The only genuinely **existing** resource this template requires is, for `sentinel-function` mode only, the
**Sentinel-enabled Log Analytics workspace** (`SENTINEL_WORKSPACE_NAME` / `SENTINEL_WORKSPACE_RESOURCE_GROUP` /
`SENTINEL_WORKSPACE_SUBSCRIPTION_ID`) -- this template never creates or enables Sentinel itself, and never
creates a Log Analytics workspace for Sentinel content (its own `monitoring.bicep` workspace is a separate,
dedicated one used only for this template's own diagnostics/App Insights, and is never the Sentinel workspace).

Every workload identity is granted the Microsoft Graph application permissions `Policy.Read.All` and
`Policy.ReadWrite.ConditionalAccess` (app role grants, no client secrets) by `scripts/postprovision.ps1` via
[`src/shared/GraphAppRoleAssignment.psm1`](src/shared/GraphAppRoleAssignment.psm1) -- idempotently, so re-running
`azd provision` never creates duplicate grants.

## Tenant bootstrap: users, group, restricted AU

`scripts/postprovision.ps1` (via [`src/shared/TenantBootstrap.psm1`](src/shared/TenantBootstrap.psm1)) is fully
idempotent and every input is independently optional:

1. **Users**: for each of the two break-glass accounts, if `EMERGENCY_ACCESS_USERn_ID` or `_UPN` is supplied
   and resolves to a real user, it is reused as-is. Otherwise a new cloud-only user is created with a
   securely-generated random password. **The initial password is generated only in memory for the single
   Graph create call, and is never logged, returned, displayed, or persisted anywhere** (not in `azd env`
   values, not in script output, not in any file) -- you must set the account's password yourself via the
   Entra admin center (or immediately configure a Temporary Access Pass, see below) before first sign-in.
2. **Group**: reused if `EMERGENCY_ACCESS_GROUP_ID` is supplied and resolves; otherwise created as a
   cloud-only, non-assigned security group containing both users.
3. **Restricted administrative unit**: reused if `EMERGENCY_ACCESS_AU_ID` is supplied and resolves; otherwise
   created with `isMemberManagementRestricted: true` and both users plus the group added as members.
4. **Global Administrator**: both users are granted the **Global Administrator** role, assigned tenant-wide
   (not scoped to the restricted AU -- Entra does not support AU-scoped Global Administrator, and break-glass
   accounts must retain full, unrestricted tenant access by design). The assignment is permanent (no PIM
   eligible/time-bound assignment), consistent with standard break-glass guidance.
5. Set `AZD_SKIP_TENANT_BOOTSTRAP=true` to skip all of the above entirely (for example, if you manage
   break-glass accounts through a separate process) -- in that case you must set `EMERGENCY_ACCESS_GROUP_ID`
   yourself so the remediation resources have something to exclude.

> **Restricted administrative unit caveat**: restricted management is defense in depth, not a boundary
> against the tenant's highest-privileged roles. Global Administrators and Privileged Role Administrators
> can still manage restricted objects and assign tenant-wide roles to their members. Use the AU to reduce
> routine administrative exposure while tightly controlling and monitoring those privileged roles.

## Temporary Access Pass and passkeys

Controlled by `AZD_ENABLE_TAP_POLICY` (default `false`):

- **`true`**: `scripts/postprovision.ps1` (via [`src/shared/TemporaryAccessPass.psm1`](src/shared/TemporaryAccessPass.psm1))
  enables the tenant's Temporary Access Pass authentication method policy, scoping it to (at minimum) the
  emergency access group via `includeTargets`, and creates a **reusable, 2-hour** Temporary Access Pass
  (`isUsableOnce: false`) for each of the two users.
- **`false`, interactive session**: you are prompted at postprovision time whether to enable TAP now; answering
  yes performs the same steps as `true` above for this run only (it does not change the persisted default).
- **`false`, non-interactive session** (CI/CD, `--no-prompt`): TAP is skipped entirely, silently but
  informatively (a message explains how to enable it later).
- **TAP values are shown exactly once**, printed directly to the interactive console only, and are **never**
  written to an `azd` environment variable, a file, a Bicep/ARM output, or any log. Microsoft Graph itself
  never re-displays a TAP's value after creation, so if you lose it, delete and recreate the TAP.
- **On failure** (for example, insufficient Graph permissions, or the tenant blocking TAP policy changes),
  the script completes the rest of postprovision successfully and prints explicit remediation instructions:
  enable the Temporary Access Pass policy yourself (Entra admin center -> Protection -> Authentication methods),
  create a TAP for each break-glass user, sign in with it, and **register at least two passkeys (FIDO2
  security keys) per account** -- the recommended long-term, phishing-resistant credential for break-glass
  accounts (a TAP is a bootstrap mechanism, not a permanent sign-in method).

## Microsoft Sentinel prerequisites

`sentinel-function` mode requires:

- An **existing** Log Analytics workspace with Microsoft Sentinel **already enabled** (this template does not
  enable Sentinel or create this workspace). Provide its name, resource group, and (if different from your
  deployment subscription) subscription ID.
- `AuditLogs` diagnostic logs flowing into that workspace from Microsoft Entra ID (Entra ID diagnostic settings
  -> "AuditLogs" category -> the Sentinel workspace). Without this, the NRT rule has no data to query.
- The deployer's Azure RBAC should ideally include the ability to assign **Microsoft Sentinel Automation
  Contributor** (`f4c81013-99ee-4d62-a7ee-b3f1f648599a`) on the playbook's resource group, so the Sentinel
  automation rule can invoke the playbook. `scripts/postprovision.ps1` attempts this automatically. If the
  deployer lacks `Microsoft.Authorization/roleAssignments/write` at that scope, the script **does not fail** --
  it prints the exact `az role assignment create` command (and the target principal: the first-party
  "Azure Security Insights" service principal) for a subscription/RG owner to run afterward.
- `infra/modules/sentinelContent.bicep` deploys the NRT analytics rule and automation rule **into the existing
  workspace's resource group** (which may be a different resource group, and even a different subscription,
  than this template's own resource group) using a cross-scope module (`scope: resourceGroup(subId, rgName)`).

## Security model

- **No Key Vault, anywhere.** No secrets are stored in Key Vault because none of this template's identities
  use secrets: every Azure-to-Azure and Azure-to-Graph call uses a system- or user-assigned managed identity.
- **No Azure Functions keys, no anonymous auth.** The `function-scheduled` timer trigger requires no external
  callers at all. The `sentinel-function` HTTP trigger uses Functions **Easy Auth V2** (Entra ID provider) with
  `unauthenticatedClientAction: RedirectToLoginPage` disabled in favor of rejecting unauthenticated calls
  outright, and `defaultAuthorizationPolicy.allowedPrincipals.identities` restricted to **only** the Sentinel
  playbook's own managed identity principal ID -- no function key, no host key, no anonymous access level.
- **Identity-based Storage, shared key access disabled.** The Flex Consumption Storage account backing the
  Function App has `allowSharedKeyAccess: false`; the Function App's deployment storage and AzureWebJobsStorage
  connections both use the user-assigned managed identity (`identity`-based connection strings), never an
  account key or connection string with an embedded key.
- **No client secrets for Graph.** Every workload identity is granted Graph **application permissions** (app
  roles) directly -- `Policy.Read.All` and `Policy.ReadWrite.ConditionalAccess` -- and authenticates to Graph
  using its managed identity token, never a registered application's client secret.
- **Least-privilege PATCH.** The remediation logic never rewrites an entire Conditional Access policy; it PATCHes
  only the `conditions.users.excludeGroups` array, and only when the emergency group is actually missing from it.
- **No passwords or TAP values ever logged/persisted.** See [Tenant bootstrap](#tenant-bootstrap-users-group-restricted-au)
  and [Temporary Access Pass](#temporary-access-pass-and-passkeys) above.

## Verification

After `azd up` completes:

```powershell
# Confirm the emergency access group is now excluded from every Conditional Access policy:
az rest --method GET --url "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?`$select=displayName,conditions" |
  ConvertFrom-Json | Select-Object -ExpandProperty value |
  ForEach-Object { [pscustomobject]@{ Policy = $_.displayName; ExcludesEmergencyGroup = ($_.conditions.users.excludeGroups -contains $(azd env get-value EMERGENCY_ACCESS_GROUP_ID)) } }

# automation-scheduled: check the last job result
az automation job list --automation-account-name $(azd env get-value AUTOMATION_ACCOUNT_NAME) -g $(azd env get-value RESOURCE_GROUP_NAME) -o table

# function-scheduled / sentinel-function: tail Application Insights / Log Stream
az functionapp log tail --name $(azd env get-value FUNCTION_APP_NAME) -g $(azd env get-value RESOURCE_GROUP_NAME)

# logicapp-scheduled: check recent runs
az logic workflow list-runs --name $(azd env get-value LOGIC_APP_SCHEDULED_NAME) -g $(azd env get-value RESOURCE_GROUP_NAME) -o table

# sentinel-function: force an end-to-end test by editing any CA policy's description in the portal, then
# watch for a Sentinel alert (Microsoft Sentinel -> Incidents & alerts, or the "SecurityAlert" table) and
# confirm the playbook run succeeded (Microsoft Sentinel -> Automation -> the alert-created rule -> Logic app runs).
```

Run `scripts/test.ps1` locally at any time to re-validate the PowerShell syntax, the Pester suite (fully
mocked, no live tenant required), and `az bicep build` -- see [Repository layout](#repository-layout).

## Cleanup

```powershell
azd down --purge
```

For `sentinel-function`, the `predown` hook first removes the template-owned analytics and automation rules
from the existing Sentinel workspace's resource group. It never deletes or disables the existing workspace.
If external-rule cleanup cannot be confirmed, teardown stops rather than orphaning Sentinel content.

`azd down` **does not** touch Microsoft Entra tenant objects, because deleting break-glass accounts,
their group, or their administrative unit must never be automated silently. To remove tenant objects that this
specific azd environment created, run the ownership-aware cleanup script explicitly:

```powershell
.\scripts\Remove-TenantObjects.ps1 -DeleteTenantObjects
```

The script compares each current object ID with an environment-specific creation marker and skips supplied or
reused objects. It also removes the Function authentication app registration only when that exact app object
was created by this environment. Review every confirmation carefully; deletion is permanent.

## Future work (not implemented)

This template deliberately does **not** create any **Azure Monitor scheduled query alert rules** (a possible
alternative/complementary detection mechanism to the Sentinel NRT rule used in `sentinel-function` mode, for
tenants that have Log Analytics but not Microsoft Sentinel). This is an intentional scope boundary for this
version of the template, tracked here as a TODO for a future contribution:

- [ ] Add an optional deployment mode (or an add-on to any mode) that creates an Azure Monitor **scheduled
      query rule** against `AuditLogs` (equivalent detection logic to the Sentinel NRT query in this README)
      for tenants without Microsoft Sentinel, firing an Azure Monitor **action group** (webhook/Function) to
      perform the same single-policy remediation as `sentinel-function` mode.

## Repository layout

```
azure.yaml                          azd project file: template metadata, preprovision/postprovision hooks
metadata.json                       azd template gallery/discovery metadata
infra/
  main.bicep                        Subscription-scoped entry point; selects mode-specific modules
  main.parameters.json              Parameters sourced from azd environment values
  modules/
    monitoring.bicep                Log Analytics workspace + (function modes only) Application Insights
    identity.bicep                  User-assigned managed identity (function modes)
    storage.bicep                   Identity-based Storage account for Flex Consumption deployment (shared key access disabled)
    function.bicep                  Azure Functions Flex Consumption FC1 app (PowerShell 7.4, Functions v4)
    automation.bicep                Azure Automation account, runbook, schedule/job link (automation-scheduled)
    logicAppScheduled.bicep         Consumption Logic App with a recurrence trigger (logicapp-scheduled)
    sentinelPlaybook.bicep          Alert-triggered Consumption Logic App playbook (sentinel-function)
    sentinelContent.bicep           NRT analytics rule + automation rule, deployed into the existing Sentinel workspace's RG
scripts/
  preprovision.ps1                  Strict AZD_DEPLOYMENT_MODE/env validation + defaults; Entra app reg for Easy Auth
  postprovision.ps1                 Tenant bootstrap, TAP, Graph app-role grants, resource config patching, publishing
  predown.ps1                       Removes external Sentinel rules before azd resource-group teardown
  Remove-TenantObjects.ps1          Explicit ownership-aware cleanup for tenant objects
  Publish-AutomationRunbook.ps1     Concatenates shared module + wrapper and publishes the Automation runbook
  Publish-FunctionApp.ps1           Packages src/function (+ shared module) and deploys via `az functionapp deploy`
  test.ps1                         Local validation entry point (syntax + Pester + bicep build)
src/
  shared/
    EmergencyAccessRemediation.psm1 Core remediation logic (Graph read/patch, preserves/appends exclusions)
    GraphAppRoleAssignment.psm1     Idempotent Graph application (app role) permission grants
    PreprovisionSupport.psm1        preprovision.ps1 helper functions (env defaults, Entra app reg, Sentinel checks)
    TenantBootstrap.psm1            Idempotent users/group/restricted AU/Global Administrator role assignment
    TemporaryAccessPass.psm1        Idempotent TAP policy + reusable 2-hour TAP creation
  automation/
    EmergencyAccessRemediation.ps1  Thin runbook wrapper: Connect-MgGraph -Identity, calls the shared module
  function/
    host.json, profile.ps1, requirements.psd1, .funcignore
    RemediateCAPolicies/            Timer trigger (function-scheduled): remediates all policies
    HttpRemediateCAPolicy/          Entra-protected HTTP trigger (sentinel-function): remediates one CAPolicyId
tests/
  EmergencyAccessRemediation.Tests.ps1   Pester 5 suite, fully mocked Microsoft Graph calls
.gitignore, .funcignore (repo root; src/function/.funcignore is the one that matters for packaging)
```

## References

- [Manage emergency access (break-glass) accounts](https://learn.microsoft.com/entra/identity/role-based-access-control/security-emergency-access)
- [Conditional Access: exclude emergency access accounts](https://learn.microsoft.com/entra/identity/conditional-access/plan-conditional-access#exclude-emergency-access-or-break-glass-accounts)
- [Restricted management administrative units](https://learn.microsoft.com/entra/identity/role-based-access-control/admin-units-restricted-management)
- [Temporary Access Pass authentication method](https://learn.microsoft.com/entra/identity/authentication/howto-authentication-temporary-access-pass)
- [Azure Functions Flex Consumption plan](https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan)
- [Azure Functions authentication and authorization (Easy Auth) with Microsoft Entra](https://learn.microsoft.com/azure/app-service/overview-authentication-authorization)
- [Microsoft Sentinel automation rules](https://learn.microsoft.com/azure/sentinel/automation/automation-rules)
- [Microsoft Sentinel near-real-time (NRT) analytics rules](https://learn.microsoft.com/azure/sentinel/detect-threats-custom#nrt)
- [Azure Developer CLI: `azd` templates](https://learn.microsoft.com/azure/developer/azure-developer-cli/make-azd-compatible)
