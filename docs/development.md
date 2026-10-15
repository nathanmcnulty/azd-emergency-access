# Development and publishing

[Back to the quickstart](../README.md)

## Validate a change

Run the same core checks used by GitHub Actions:

```powershell
$result = Invoke-Pester ./tests -PassThru
if ($result.FailedCount -gt 0) { throw 'Pester validation failed.' }

az bicep build --file ./infra/main.bicep
git diff --exit-code -- ./infra/main.json
```

The repository's [`.gitattributes`](../.gitattributes) keeps Bicep and embedded PowerShell inputs on LF endings so Windows and Linux produce the same ARM template hash.

Also parse all PowerShell files and JSON metadata before publishing. The `Validate template` workflow performs these checks on pull requests and `main`.

## Generated ARM template

[`infra/main.bicep`](../infra/main.bicep) is the source of truth and [`infra/main.json`](../infra/main.json) is its checked-in generated form. Always regenerate and review both together after changing Bicep. Do not hand-edit the generated JSON.

## Catalog metadata

Public catalog metadata is stored in [`.azd/catalog.json`](../.azd/catalog.json). Keep its quickstart synchronized with the root README and test the real public-template initialization path before release.

Changes to catalog inputs on `main` trigger [the publishing workflow](../.github/workflows/publish-azd-catalog.yml). It sends an `azd-catalog-updated` repository dispatch to `nathanmcnulty/azd-website`.

`AZD_CATALOG_TOKEN` should be a fine-grained repository secret able to send repository dispatches to `nathanmcnulty/azd-website` with repository Contents read/write access. When the secret is absent, the workflow reports that publishing was skipped without failing template validation.

## Pull-request expectations

- Keep GitHub Actions pinned by full commit SHA.
- Preserve generated ARM parity.
- Pin PowerShell modules and Bicep versions exactly, and validate dependency updates before merging them.
- Add focused tests for lifecycle, ownership, authentication, and administrator-facing contract changes.
- Never introduce device-code authentication or stored credentials.
- Do not weaken exact-ownership teardown guards to make cleanup more convenient.

Protect `main` with required pull requests and the `validate` status check. Create releases only from a verified, GitHub-signed commit on protected `main`, enable immutable GitHub releases, and verify the release attestation after publication. Direct production consumers to a protected versioned tag or immutable commit rather than floating `main`.

## Hosted runtime baseline

The Function Flex worker and Automation runtime select PowerShell 7.6, which
uses .NET 10 LTS. Automation selects the documented 7.6 default Az package
`15.1.0`, replacing the 7.4-specific `12.3.0` default. See Microsoft's [Functions runtime contract](https://learn.microsoft.com/en-us/azure/azure-functions/functions-reference-powershell#powershell-versions)
and [Automation runbook support](https://learn.microsoft.com/en-us/azure/automation/automation-runbook-types#powershell-runbooks).
This source upgrade changes no hosting plan, identity, permissions or schedule
definition. It does not prove startup or job execution in a selected region.

For an existing Automation deployment, an approved redeployment creates
`PowerShell-7-6` and rebinds the owned runbook to it. The retained
`PowerShell-7-4` environment is not deleted. Inspect the selected account, pause
and verify the owned schedule before rebinding, verify the deployed runtime and
runbook binding, and run an explicitly authorized synthetic job before resuming
the schedule. A Function configuration update restarts the worker; verify
startup, dependency import and a synthetic invocation before production use.
Do not run `azd up` just to validate this source change.

These are operator approval gates, not an implemented paused-migration
workflow. Provisioning also writes schedule/association resources; this source
PR does not establish that an earlier pause survives redeployment or provide a
pause/resume mechanism. Require a separately reviewed paused-migration
procedure before live use, with authoritative schedule/timer readback after
every deployment step and separate approval to resume processing.
