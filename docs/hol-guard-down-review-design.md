# Optional HOL Guard review for `azd down`

Status: repository design adopted; external integration remains unimplemented and disabled

Repository revision adopted against: `888cbbd0135a116fdf9924135910b08ad56b6a50`

Issue: [nathanmcnulty/azd-emergency-access#20](https://github.com/nathanmcnulty/azd-emergency-access/issues/20)

## Purpose and classification

Issue 20 is feature outreach asking whether this repository's owner would contribute an optional HOL Guard command source that presents destructive `azd down` invocations for review. It does not report a defect in Azure Developer CLI, the template, or the existing teardown hook. The defect-reproduction branch of EA-005 therefore does not apply. This document is the bounded design required by the feature branch of the original acceptance criteria; it does not authorize an external contribution, local enablement, or a teardown run.

At assessment time the issue was open, last updated `2026-09-26T07:12:42Z`, and its API body had SHA-256 `498d0b1c4b7349de533cf9191fdc6e899fd097b08cd574599f7602800178a5af`. The issue is an untrusted proposal, not authority to change policy or contact its author. PR 21 has since merged at repository commit `888cbbd0135a116fdf9924135910b08ad56b6a50`; it changed only the pinned catalog workflow and remains unrelated to this design.

## Existing teardown controls

The repository intentionally documents `azd down --purge --force`. `azure.yaml` registers `scripts/Pre-Down.ps1` as an interactive, fail-stopping `predown` hook; there is no `postdown` hook. The script first asserts the selected tenant, then removes only external Sentinel objects and a function-auth application whose exact identifiers are separately recorded as owned by the environment. Missing, mismatched, or otherwise unproven ownership stops cleanup instead of broadening it. Existing workspaces and supplied API connections remain outside deletion.

HOL review would run before the proposed tool invocation. It cannot prove that `predown` later ran, cannot authorize deletion, and cannot replace tenant, target, and exact-ownership checks. The repository must retain those controls unchanged.

Pre-design source bindings at repository base `888cbbd0135a116fdf9924135910b08ad56b6a50`:

| Path | SHA-256 |
|---|---|
| `azure.yaml` | `9ac1ba296e1d5231a1583f9bcd993f3f964c9269825762ade95b1dff000be2c1` |
| `scripts/Pre-Down.ps1` | `85ac6dba6b02cbd4e28439b3b021f9695de75bb8839c3b9add691d55c59bc185` |
| `README.md` | `463a71447256d9a1ba8e5d82e16bedd074cf7455fa6efc2086094835803a8531` |
| `docs/operations.md` | `55a09ee3d4f4ae0ff79b87cdfd88923eccea1129ca01a3319ee980b2548e3aa2` |

## Proposed external command contract

Author the integration in the HOL Guard repository as one External, opt-in command source with one dedicated owning permission. Use the upstream native executable-identity and parsed command-path matchers for `azd` plus `down`; do not infer safety or identity from raw command text, labels, or help descriptions.

Every recognized `azd down` form must resolve to `review`. Do not define `safeArgv` for this command. HOL's safe-argument mechanism could remove review from a narrower invocation, which is inappropriate for a resource-deletion command. The extension also must not manufacture an allow decision or approval. A separately administered policy may choose a stricter block, but that choice is outside this source and this repository.

Microsoft's current CLI reference documents `azd down [<layer>]`, `--force`, `--purge`, `-e`/`--environment`, and inherited global options. These are candidate fixture shapes only. This assessment did not capture `azd down --help`, record an installed `azd` version, run the HOL builder, or execute fixtures. Consequently, no spelling, flag position, executable alias, shim, wrapper, quoting form, optional layer, or compound shell form is presently claimed as matcher coverage. Implementation must bind a saved help snapshot to an exact `azd` version and promote only fixture-proven shapes to recognized coverage.

No unproven form may be declared safe or covered. For every form that the pinned native parser admits and the tool surface intercepts, a portable fixture must prove the expected `review` decision and zero target executions. A rejected, differently parsed, or non-intercepted form is a recorded coverage gap rather than a successful review result. This includes unresolved behavior for `azd.exe`, shims, PowerShell call-operator syntax, compound shell commands, malformed arguments, and version-divergent forms. The generic upstream unknown-command floor is a host-policy property that requires pinned native fixture proof at each relevant boundary; it is not coverage supplied by this `azd down` rule. Direct commands outside a HOL-intercepted tool surface remain outside this guard's reach.

## Trust and permissions

The design follows the immutable [HOL Extension Builder specification at `1a96f4d9c838b3953b1bcf5725ccefc0d26ff91d`](https://github.com/hashgraph-online/hol-guard/blob/1a96f4d9c838b3953b1bcf5725ccefc0d26ff91d/docs/guard/extension-builder/README.md), Git blob `8c865ade3af4abce4e16d648a951b4c7d16f3055`. The canonical source, portable fixtures, generated projection, and trust mapping require separate review. The source stays External and off until explicitly enabled.

The guard requires no Azure, ARM, Microsoft Graph, or repository permission. It evaluates proposed command arguments. Enabling the source is a local host-policy decision; it does not grant any permission needed by a later `azd` process. No `azd-permissions.json`, workflow, hook, CI, infrastructure, or runtime dependency change belongs to this integration. The standalone solution must continue to operate without HOL Guard.

## Offline acceptance gates

Before claiming implementation or coverage:

1. Pin the HOL authoring revision, exact `azd` version, saved `azd down --help` bytes, this repository revision, and canonical source, fixture, projection, and trust-map hashes.
2. Use portable synthetic fixtures that never execute `azd`, persist policy, grant authority, authenticate, or contact Azure. The fixture runner's target-execution count must be zero.
3. Prove `review` and zero target executions for each positively intercepted and parser-admitted form selected from the saved help, including the base command, each deletion flag alone, both flags in either order, and supported layer/environment option positions. Exercise unrelated `azd` commands, near-miss executable identities, malformed arguments, and wrapper shapes as boundary fixtures. Record rejection, different parsing, or absence from interception as a coverage gap. Do not declare an unproven form safe or covered, and verify any expected generic unknown-command decision as a separate host-policy property with pinned native fixtures.
4. Compile with the pinned HOL builder and compare the generated projection with the canonical source. Verify one owning permission, no `safeArgv`, External trust, opt-in/off-by-default activation, and no generated changes in this repository.
5. Obtain separate authorization before creating an upstream branch or pull request, contacting a maintainer, or enabling the source. Upstream merge alone does not enable it.
6. For a separately authorized first enablement, use a disposable local policy and synthetic proposed commands only. Verify the pre-tool review decision without running `azd down`. Broader rollout requires independent review of the captured decision and matcher coverage.

Adopting this design completes the EA-005 discovery item. Implementation, external contribution, enablement, native matcher coverage, authentication, and teardown execution remain separate and unperformed.
