# Backlog: nathanmcnulty/azd-emergency-access

> Generated from `docs/backlog.json`. Edit the JSON source and regenerate this file.
> Standard: [azd agent backlog standard](https://github.com/nathanmcnulty/azd-reference/blob/main/standards/agent-backlogs.md). This link is review guidance, not a runtime dependency.

- **Schema version:** 1.0.0
- **Repository:** nathanmcnulty/azd-emergency-access
- **Source revision:** `80450b0cf55ada25d97d322a3ff036ba6d8e236a`
- **Captured:** 2026-10-04
- **Items:** 5

## EA-001: Reconcile this backlog with current source and active work

- **Kind:** discovery
- **Priority:** P1
- **Status:** done
- **Wave:** 0
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Plans and implementation evidence are spread across files; the captured source can change while other tasks work.

**Scope:**

- docs/backlog.json
- docs/backlog.md
- Existing roadmap, execution status, open issues and pull requests &lpar;read-only&rpar;

**Acceptance:**

- Classify each candidate as implemented, still open, superseded or awaiting evidence; retain source links and reasons.
- Inspect dirty state, remotes, worktrees and local environment presence without reading secrets; avoid duplicate work with active owners.
- Resolve the actual offline validation commands and record exact current default-branch/working-tree provenance; do not copy historical live passes to newer code.

**Validation:**

- git status --short
- git remote -v
- git worktree list --porcelain
- Read the applicable instructions and validation workflow; read gh issue list and gh pr list for the named repository using nathanmcnulty. Do not create or modify issues/PRs.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md
- https&colon;//github.com/nathanmcnulty/azd-emergency-access/pull/21
- https&colon;//github.com/nathanmcnulty/azd-emergency-access/issues/20

**Evidence:**

- Current-main reconciliation used exact revision 80450b0cf55ada25d97d322a3ff036ba6d8e236a. EA-002 remains proposed pending live onboarding, alert-route and recovery evidence; EA-003 remains proposed pending a bounded optional-monitoring design; EA-004 is complete from the reviewed component packet; EA-005 remains proposed because issue &num;20 is open and has not received the required focused reproduction.
- Read-only GitHub reconciliation on 2026-10-04 found issue &num;20 open with no closing pull request and dependency PR &num;21 open; current main is merged PR &num;18. No runtime, dependency, permission or issue/PR mutation was performed.
- The canonical permission-tracking checkout and its local .azure state were left untouched and no environment values were read. The owned worktree started clean from current origin/main; focused validation passed 9/9 and the final packet passed 114/114 Pester tests plus Bicep and diff checks.

**Review and authorization note:**

Review EA-001 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## EA-004: Adopt reviewed deployment-validation 1.1.1

- **Kind:** maintenance
- **Priority:** P1
- **Status:** done
- **Wave:** 1
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

At initial capture the lock recorded deployment-validation 1.0.0; this packet adopts the compatible signed 1.1.1 release.

**Scope:**

- azd-components.lock.json
- scripts/vendor/Azd.DeploymentValidation/
- tests/
- docs/

**Acceptance:**

- Review the exact 1.0.0-to-1.1.1 diff and current consumer hashes before deciding to adopt.
- Prepare only the compatible managed files and lock in one owned worktree; retain domain validation extensions.
- Offline validation and commit-only rollback are required; live deployment and publication are separately authorized.

**Validation:**

- From the solution root run ./scripts/Test-Repository.ps1
- Run focused tests for changed behavior from tests/; fixtures do not prove live-service or endpoint behavior.
- After separate authorization, retain redacted exact-target live evidence and cleanup results outside public Git. Do not execute live operations from this backlog alone.

**Dependencies:**

- _none_

**Components:**

- deployment-validation

**Sources:**

- azd-components.lock.json

**Evidence:**

- Independent frozen-file review passed four files at source base d62c210e53e97af2d5c7b5ea664c78e5c66699bd; diff SHA256 ba2d4beb96768446e8a336cf243ef2832ccb4b16ed83dd96a2c04cfffa4b650c. Managed bytes match signed source revision 0c96cc89c554ffc3b3ca82ceda12da6591e816c1.
- Full offline Test-Repository passed 114/114 tests plus Bicep and diff checks. Focused consumer tests passed 9/9; the reviewer reran 9/9 and a schema 1.0 plan/no-provider-call smoke 1/1. Component drift reported all five files current and exact.
- The Graph authentication component 0.1.1, domain adapter, permissions and unbound schema 1.0 output remain unchanged. No Azure, Graph, HTTP delivery or permission operation was needed. Reviewed lock values and exact managed bytes were integrated after clean-path/base checks; release and optional evidence-binding adoption remain separate gates.
- Reconciled the same reviewed component bytes onto current main 80450b0cf55ada25d97d322a3ff036ba6d8e236a while leaving Graph authentication 0.1.1, permissions, provider and delivery behavior unchanged. Focused deployment validation passed 9/9; the final packet passed 114/114 Pester tests plus Bicep and diff checks.

**Review and authorization note:**

Review EA-004 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## EA-002: Qualify onboarding, alert routes and independent recovery drill

- **Kind:** verification
- **Priority:** P1
- **Status:** proposed
- **Wave:** 2
- **Authorization:** tenant-write
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

The emergency workflow requires retained alert and recovery evidence beyond resource readiness.

**Scope:**

- docs/
- scripts/Test-Deployment.ps1
- tests/

**Acceptance:**

- Record selected account/group onboarding, sign-in alert and optional activity/notification outcomes.
- Prove the independent recovery path, owned-object cleanup and recovery material custody.
- Do not weaken emergency exclusions or claim recipient receipt from a successful Logic App run.

**Validation:**

- From the solution root run ./scripts/Test-Repository.ps1
- Run focused tests for changed behavior from tests/; fixtures do not prove live-service or endpoint behavior.
- After separate authorization, retain redacted exact-target live evidence and cleanup results outside public Git. Do not execute live operations from this backlog alone.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- README.md

**Evidence:**

- _none_

**Review and authorization note:**

Review EA-002 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## EA-003: Design optional workspace discovery and central health monitoring

- **Kind:** discovery
- **Priority:** P2
- **Status:** proposed
- **Wave:** 3
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Future admin-experience improvements need bounded resource selection and independent optional behavior.

**Scope:**

- scripts/
- infra/
- docs/
- azd-permissions.json

**Acceptance:**

- Discovery is read-only and requires exact workspace selection; unavailable/cross-tenant targets stop.
- Optional health uses deployment-validation or Azure Monitor only for compatible signals.
- Sentinel analytics and incident automation stay solution-owned; no forced monitoring dependency or inferred enforcement.

**Validation:**

- From the solution root run ./scripts/Test-Repository.ps1
- Run focused tests for changed behavior from tests/; fixtures do not prove live-service or endpoint behavior.

**Dependencies:**

- _none_

**Components:**

- deployment-validation
- azure-monitor-scheduled-query-notifications

**Sources:**

- README.md

**Evidence:**

- _none_

**Review and authorization note:**

Review EA-003 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.

## EA-005: HOL Guard rule for &grave;azd down --purge --force&grave;?

- **Kind:** discovery
- **Priority:** P2
- **Status:** proposed
- **Wave:** 3
- **Authorization:** local-only
- **Blocker:** _none_
- **Claim:** _none_

**Problem:**

Open GitHub report captured 2026-10-03. Reproduce against the current source and reconcile active PRs before changing code; the issue remains the detailed trigger/evidence reference.

**Scope:**

- Paths and trigger cited in the linked issue
- Focused offline regression tests
- docs/

**Acceptance:**

- Classify the report as still reproducible, already fixed, superseded or requiring live evidence; record the exact current revision.
- For a reproducible defect, demonstrate the linked trigger with an offline regression and apply the smallest fix preserving tenant/target/ownership and failure semantics.
- For a feature, produce a bounded design with compatibility, optional permissions, acceptance and rollout gates before implementation; no live mutation or automatic issue closure.

**Validation:**

- Read the issue body and current source/PRs; capture the exact reproduction and existing registered offline validation command.
- Use deterministic fixtures for the described trigger and negative boundary; retain current-source results. Do not rerun production or tenant operations to reproduce it.

**Dependencies:**

- _none_

**Components:**

- _none_

**Sources:**

- https&colon;//github.com/nathanmcnulty/azd-emergency-access/issues/20
- README.md

**Evidence:**

- Read-only reconciliation on 2026-10-04 confirmed issue &num;20 remains open with no closing pull request at current main 80450b0cf55ada25d97d322a3ff036ba6d8e236a.
- No deterministic reproduction or focused regression for the reported azd down trigger was run in this component-only packet, so the item remains proposed and no source change is claimed.

**Review and authorization note:**

Review EA-005 against the current repository state. Its status or authorization class is not eligible for an actionable generated handoff. Do not claim or execute it without explicit selection, satisfied dependencies, and every required authorization. Never interpret this generated view as approval.
