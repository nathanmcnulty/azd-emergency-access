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
- Add focused tests for lifecycle, ownership, authentication, and administrator-facing contract changes.
- Never introduce device-code authentication or stored credentials.
- Do not weaken exact-ownership teardown guards to make cleanup more convenient.
