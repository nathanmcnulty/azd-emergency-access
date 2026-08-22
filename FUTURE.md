# Future administrator experience

These ideas are intentionally deferred. They are useful, but should not make the core `azd init` and `azd up` path heavier or less reliable.

## Discover monitoring workspaces

**Goal:** Replace manual subscription, resource-group, and workspace entry with a guided selection of accessible Log Analytics and Microsoft Sentinel workspaces.

**Feasibility:** Moderate. An azd preprovision hook can query Azure CLI and present a terminal menu. The graphical wizard can provide a richer searchable picker using the same azd environment variables.

**Important boundaries:**

- Preserve manual entry for cross-subscription, restricted, and noninteractive deployments.
- Distinguish ordinary Log Analytics workspaces from workspaces onboarded to Microsoft Sentinel.
- Validate that `SigninLogs` and, when needed, `AuditLogs` are actually available; workspace existence alone is insufficient.
- Reuse the selected workspace for both alerting paths when possible.
- Do not request broader Azure permissions solely to improve discovery.

**Completion criteria:** An administrator can select a discovered workspace, choose manual entry, or configure alerting later, and the resulting azd environment passes the existing validation contract.

## Central health monitoring

**Goal:** Detect when emergency-access protection is no longer dependable—for example, a disabled or failing remediator, missing Entra log ingestion, unhealthy analytics rules, or a broken notification connection.

**Feasibility:** Best delivered as a separate, organization-wide solution rather than more resources in every emergency-access deployment. The template should expose stable resource IDs and status signals that the central monitor can consume.

**Important boundaries:**

- Monitor all emergency-access deployments across subscriptions from one operational location.
- Alert on sustained failure or missing expected signals without generating noisy per-run incidents.
- Check notification delivery health, not merely whether an API connection resource reports `Connected`.
- Keep delayed audit export and long-term retention separate from urgent sign-in notification paths.
- Do not automate real emergency-account sign-ins or store passkeys to test credentials.

**Completion criteria:** Operators receive one actionable health alert when a protection or notification path is persistently unhealthy, with the affected environment and remediation link identified.

## Periodic recovery drills

Microsoft recommends validating emergency access accounts at least every 90 days. Automation can schedule reminders and record evidence, but a custodian must still prove that the independently stored passkeys can be retrieved and used.

Future orchestration may provide a checklist, due-date tracking, and evidence export. It must not perform unattended sign-ins, weaken Conditional Access, or treat resource health as proof that account recovery works.
