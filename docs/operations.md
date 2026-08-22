# Operations

[Back to the quickstart](../README.md)

## Verify a deployment

1. Confirm both emergency accounts can sign in with their registered passkeys.
2. Confirm the emergency group is excluded from every applicable Conditional Access policy.
3. Use an approved report-only test policy to prove remediation and idempotency.
4. Confirm Azure Monitor email for both a successful and failed test sign-in when enabled.
5. Confirm the Sentinel incident, Logic App run, Teams message, and optional email when enabled.
6. Perform an approved harmless directory change with a test emergency account and confirm the activity detection.
7. Record the drill results, custodians, recovery devices, and any remediation work.

Repository validation:

```powershell
Invoke-Pester ./tests
az bicep build --file ./infra/main.bicep
git diff --exit-code -- ./infra/main.json
```

## Common problems

- **A prerequisite command is missing:** install the tool named by the error and rerun `azd up`; the deployment is idempotent.
- **Microsoft Graph returns HTTP 403:** confirm the tenant, activated Entra role, and delegated consent. Azure Owner does not grant Graph privileges.
- **The cached Graph context lacks scopes:** run the one standard `Connect-MgGraph` initialization described by the error. Do not use device-code authentication.
- **Function deployment fails:** confirm Azure CLI can access the Function App and rerun `azd deploy` or `azd up`. The template builds a ready-to-run ZIP locally and uploads it with Azure CLI.
- **Function returns 401 or 403:** confirm Easy Auth, its application audience, and the allowed playbook principal.
- **Sentinel automation does not run:** confirm `AuditLogs` ingestion, NRT rule health, Automation Contributor on the playbook resource group, and the automation-rule condition.
- **No Teams message arrives:** reauthorize the connection owner, verify team/channel membership, and inspect the failed Logic App action without printing secrets.
- **No sign-in email arrives:** confirm the email action group and that the `SigninLogs` record reached the selected workspace.
- **TAP returns HTTP 403:** grant the required authentication-method consent and rerun `azd up`. The deployment intentionally withholds privileged role assignments until onboarding completes.

## Routine maintenance

- Exercise both accounts, both sets of passkeys, and all notification paths on an approved schedule.
- Retest Teams after connection-owner, token, Conditional Access, or channel changes.
- Retest Sentinel after connector, analytics-rule, automation-rule, or Easy Auth changes.
- Review emergency-account sign-in and audit incidents even when a drill was expected.
- Review Azure API versions, Functions runtime support, Graph permissions, and pinned GitHub Actions dependencies during template updates.

## Remove Azure resources

```powershell
azd down --purge --force
```

The predown hook deletes only exact IDs recorded as owned by this environment, including external Sentinel rules and role assignments. If ownership cannot be proven, teardown stops instead of broadening deletion. Existing workspaces and supplied API connections are never deleted.

## Remove tenant identities

Normal Azure cleanup deliberately retains the emergency accounts and group. Only after explicit approval, delete exact-owned tenant objects with:

```powershell
./scripts/Remove-TenantObjects.ps1 -DeleteObjectsCreatedByThisEnvironment
```

The script requires confirmation and deletes only objects whose current IDs match the recorded ownership IDs. Before deleting an owned emergency group, it removes that exact ID from Conditional Access exclusions and, when configured, the TAP policy. Supplied or mismatched objects are retained.

## Central monitoring and audit retention

For organization-wide coverage, use Azure Policy to route platform diagnostic settings and Azure Activity Logs into a central Log Analytics or Sentinel workspace. Configure Entra diagnostic settings once per tenant for `SigninLogs` and `AuditLogs`.

The playbook diagnostic settings in this template provide run data but do not create a separate health-alert stack. A central alert can monitor failed or disabled Logic App runs across deployments. Use a polling Function or the Microsoft 365 Management Activity API only when delayed aggregation, export, cross-tenant routing, or a destination outside Azure Monitor/Sentinel requires it.
