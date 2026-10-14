# Workspace discovery and health design

This document defines the bounded design for EA-003. It does not implement a
workspace picker, call Azure, change an azd environment, grant a role, deploy a
health alert, or choose the owner of an organization-wide monitor. The deferred
administrator experience and health-alert completion criteria remain in
[`FUTURE.md`](../FUTURE.md).

## Current behavior and remaining gaps

The existing deployment already has an exact final-input contract. When an
alerting path is enabled, `scripts/Validate-Environment.ps1` builds the canonical
workspace resource ID from the configured subscription, resource group, and
workspace name. The preprovision check verifies access and compares `AZURE_TENANT_ID` for a
different workspace subscription; its selected-subscription branch returns
without a separate tenant comparison. The separate deployment-validation
context check verifies both selected tenant and subscription. Workspace
existence and the exact `onboardingStates/default` resource are checked when
Sentinel is required. Exact IDs for Sentinel
rules, automation, role assignment, and playbook are retained for validation
and cleanup.

That validation does not discover workspaces, bind a displayed candidate list
to a selection, or prove that `SigninLogs` and `AuditLogs` are queryable. The
post-provision `SigninLogs` query is an opportunistic corroboration check. Its
failure or an empty result does not prove that ingestion, keys, or alerts failed.
The current deployment-validation checks prove that configured resources are
readable. Only the explicitly requested `-TestDelivery` mode creates a labeled
Sentinel test and inspects the Logic App run and configured actions. None of
those results proves recipient receipt or recovery-account usability.

EA-003 adds this design and source mapping only. It deliberately leaves the
current scripts, infrastructure, component lock, environment contract, and
permission surface unchanged.

## Proposed read-only discovery contract

A future adapter may enumerate Log Analytics workspaces only in subscription
IDs supplied by an administrator or by the already selected azd context. It
must not traverse other tenants or expand scope when a read fails. Provider
results are candidates, not evidence of ownership, deployment authorization,
or permission to grant roles.

The collector output must be one versioned record containing:

- `schemaVersion`, `capturedAtUtc`, collector name and version, and the target
  tenant ID from the validated session;
- every authorized subscription ID queried, plus a bounded result for each
  query (`complete`, `forbidden`, `unavailable`, or `failed`);
- for each candidate, the canonical ARM `workspaceResourceId`, subscription
  ID, resource-group name, workspace name, tenant ID, and location;
- the workspace customer ID only as informational metadata, never as the ARM
  identity or selection key;
- the exact Sentinel onboarding resource ID and state returned for that
  workspace;
- separate `SigninLogs` and `AuditLogs` probe results, including query route,
  capture time, and one of `available`, `empty`, `forbidden`, `unavailable`,
  `failed`, or `unknown`; and
- a deterministic SHA-256 digest over the normalized collector record.

`empty` means the query succeeded but returned no rows within the stated time
window. It does not mean the table is absent. A timeout, authorization failure,
partial result, or unparseable response is never converted to `empty` or
`available`.

Both `available` and `empty` are eligible queryability evidence when every
other required check passes. An empty result remains an operator-visible
ingestion-health warning; it is not proof of ongoing ingestion.

A matching unkeyed digest proves internal consistency only. It does not
authenticate the collector, prove a provider query, establish ownership, or
authorize deployment. Selection also requires independently trusted collector
execution and authenticated session/capture provenance; supplied records with
unverified provenance cannot qualify merely because their digests match.

The operator selects exactly one canonical `workspaceResourceId`. A future
selection receipt must bind the collector digest, selected resource ID, target
tenant ID, required purpose (`signin-alerts` or `sentinel-activity-alerts`),
selection time, and each required table result. Sentinel activity alerting
requires Sentinel onboarding plus successful queryability (`available` or `empty`)
for both `SigninLogs` and `AuditLogs`. Sign-in alerting requires the same queryability for `SigninLogs`. A receipt is discovery
evidence only; it cannot authorize deployment or substitute for the existing
environment validation.

Manual entry remains a required fallback. It creates the same normalized
candidate and receipt after exact read-only validation. Manual input never
bypasses tenant, existence, Sentinel, table, freshness, or digest checks. The
future picker may then write the existing `AZD_SIGNIN_LOG_WORKSPACE_*` or
`AZD_SENTINEL_WORKSPACE_*` values only after a receipt passes. The existing
validation remains authoritative for provisioning.

### Refusal matrix

| Evidence | Required result | Otherwise |
| --- | --- | --- |
| Azure context | One exact tenant and expected subscription context | Stop without changing environment values. |
| Subscription query | Complete result for every subscription included in the displayed set | Mark the set incomplete and prevent selection from it. Manual entry may be validated separately. |
| Candidate identity | One well-formed canonical ARM workspace ID whose parsed fields equal the returned fields | Reject malformed, conflicting, or duplicate records. |
| Display name | Informational only | Never select the first, newest, or same-named workspace. |
| Tenant | Candidate and subscription tenant exactly equal the target tenant | Reject cross-tenant or unknown-tenant candidates. |
| Workspace read | Exact resource exists and is readable | Reject absent, deleted, forbidden, unavailable, or unknown state. |
| Sentinel requirement | Exact onboarding state belongs to the selected workspace | Reject missing, foreign, ambiguous, or unreadable onboarding evidence. |
| Required log table | Successful, current probe for every table required by the selected purpose | Reject forbidden, unavailable, failed, unknown, or stale results. Treat `empty` as eligible queryability evidence with an operator-visible ingestion-health warning. |
| Consistency and provenance | Digest and bound fields match, and collector/session capture provenance is independently trusted | A digest alone cannot authenticate origin or authorization. Reject unverified, conflicting, mixed-run, or stale evidence. |
| Manual fallback | Same exact identity and evidence contract as discovery | Reject unverifiable input; do not downgrade checks. |

The future implementation must require an administrator-selected freshness
window. This design does not choose one. No historical candidate, cached menu,
or latest successful row may silently satisfy a new run.

## Compatible health evidence

Optional health is an independent consumer of existing stable IDs and signals.
It is not a prerequisite for this solution and does not own this solution's
Sentinel resources.

| Signal | What it can support | What it cannot prove |
| --- | --- | --- |
| Default deployment-validation report | Point-in-time context match, configured resource readability, feature decisions, and warnings | Continuous health, log freshness, recipient receipt, or account recovery |
| Explicit `-TestDelivery` result | A labeled Sentinel test reached a successful Logic App run and every configured action reported success | Human receipt, ongoing delivery, or future runs |
| `SigninLogs` / `AuditLogs` queries | Queryability and timestamped evidence of records within an explicitly stated window | Absence of events, key usability, analytics-rule execution, or delivery |
| Logic App `WorkflowRuntime` diagnostics and platform metrics | Failed, skipped, disabled, or delayed workflow execution when the signal is emitted and routed | Destination receipt or credential recovery |
| Azure Monitor scheduled-query rule state and evaluation health | Whether an already authorized central rule is enabled and evaluating its compatible query | That the protected workflow is correct or that a notification was received |
| API connection resource state | A configuration/readiness clue | Successful delivery; `Connected` alone is insufficient |

Diagnostic and query data can be delayed. A central monitor therefore needs
administrator-owned thresholds, destinations, schedules, retention, and
missing-signal semantics before it can be implemented. This repository does not
choose those policies, deploy central infrastructure, or add a per-environment
poller. A future central alert is a separate authorized change. Existing
Sentinel analytics rules, automation rule, playbook, role assignment, and
cleanup lifecycle remain solution-owned and optional.

## Permission and authority gaps

No permission is added by this design. The repository does not currently have
an `azd-permissions.json`, so EA-003 cannot truthfully record the proposed
collector's least-privilege access as an implemented permission contract.

Microsoft documents `Microsoft.OperationalInsights/workspaces/query/read` and
the `Microsoft.OperationalInsights/workspaces/tables/data/read` data action for
Log Analytics query access. Workspace enumeration and Sentinel onboarding reads
also require the applicable Azure Resource Manager reads at the administrator-
approved subscription or resource scope. The exact custom-role actions and
supported API versions must be reviewed with the future adapter. Built-in roles
are examples of published permission bundles, not approval to assign them.

Reading existing health resources and querying diagnostic data are separate
from creating alerts. Microsoft documents additional target read,
resource-group write, and action-group read permissions for creating or editing
log search alert rules. Those writes, any role grant, and the monitor's operating
identity require separate ownership and authorization. A cached session or a
successful broad-privilege test does not establish minimum permission or
consent.

## Future implementation gates

1. An administrator chooses allowed subscriptions, evidence freshness, the
   central monitor owner, signal thresholds, action destination, and recipients.
2. Implement and fixture-test a pure candidate normalizer, receipt binder, and
   refusal matrix before adding a provider adapter.
3. Review exact supported API versions and permission actions, record remaining
   unknowns, and obtain separate authorization for any grant.
4. Validate discovery against one explicitly selected tenant and subscriptions;
   retain partial and failed reads rather than broadening scope.
5. Treat picker integration, central alert deployment, delivery testing, and
   recipient confirmation as separate evidence gates.

Until those gates are met, the two completion criteria in `FUTURE.md` remain
open. Existing manual configuration and deployment validation continue to be
the supported paths.

## Primary Microsoft references

- [Query data using the Azure Resource Manager API](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/api/azure-resource-queries)
- [Manage access to Log Analytics workspaces](https://learn.microsoft.com/en-us/azure/azure-monitor/logs/granular-rbac-log-analytics)
- [Azure built-in roles for Monitor](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/monitor)
- [Log Analytics workspaces: List](https://learn.microsoft.com/en-us/rest/api/loganalytics/workspaces/list?view=rest-loganalytics-2026-03-01)
- [Microsoft Sentinel onboarding states: List](https://learn.microsoft.com/en-us/rest/api/securityinsights/sentinel-onboarding-states/list?view=rest-securityinsights-2025-09-01)
- [Monitor workflows with diagnostic data](https://learn.microsoft.com/en-us/azure/logic-apps/monitor-workflows-collect-diagnostic-data)
- [View workflow metrics](https://learn.microsoft.com/en-us/azure/logic-apps/view-workflow-metrics)
- [Azure Monitor alert types](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-types)
- [Create or edit a log search alert rule](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-create-log-alert-rule)
- [Troubleshoot Azure Monitor log search alerts](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-troubleshoot-log)
