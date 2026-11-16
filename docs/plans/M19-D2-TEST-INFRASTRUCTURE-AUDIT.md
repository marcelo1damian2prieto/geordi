# D2 — M19 Test Infrastructure Audit

**Updated:** 2026-11-16 (America/Buenos_Aires)  
**Audit branch:** `d2/audit-boundaries-fix`  
**Base:** `m19` at `6afb4177135824165c45e2db07f86ebc6d5b00de`

## Scope

Review the capture-generation regression harness, the M10–M14 fixture replacement boundaries, and the GitLab validation/cleanup path. This audit does not authorize M19 acceptance, CI activation, runtime smoke, TLS changes, capture mutation, or protected-volume operations.

## Findings

### D2-01 — Stale source markers prevented the Boundaries case from reaching its assertions

**Severity:** Blocking for Gate 5 / `Boundaries`.

The `Boundaries` case in `scripts/Test-GeordiCaptureGenerations.ps1` used source fragments that no longer matched the implementation:

- M10 performs the Compose removal as a direct command and delegates recreation to `GeordiM10BackendReplacement.ps1`.
- M11 passes `--no-deps` in its controlled Compose replacement arguments.
- M12 passes a computed `$legacyCaptureServices` collection and delegates Collector/backend replacement to dedicated helpers.

The checkpoint's reported failure at the lifecycle marker is consistent with this mismatch. These preconditions run before the synthetic generation assertions, so a stale marker can make the test fail without testing the generation model.

**Correction on this branch:** update the markers to the current call sites and helper implementations. No production script was changed.

### D2-02 — The synthetic M12 generation sequence omitted the Collector replacement

**Severity:** Blocking for the accuracy of the generation-boundary model.

The implementation in `verify-alert-scheduling.ps1` performs an M12 controlled replacement of `otel-collector` and an M12 controlled replacement of `backend`. The Collector replacement occurs inside the backend replacement callback before the M12 backend recreation. The previous synthetic sequence represented only the backend M12 boundary and expected two Collector generations (initial plus M13).

That model contradicted the current implementation. It could not provide reliable evidence that every real service generation was represented.

**Correction on this branch:**

- Add the M12 Collector replacement before the M12 backend replacement in the synthetic stage sequence.
- Expect three Collector generations: initial, M12, and M13.
- Update the emitted boundary summary to report Collector recreation at M12 and M13.

The test continues to assert old-generation sealing, immutable evidence, exact old/new container attribution, completed handoffs, generation ordering, scanner inventory, and fail-closed rejection cases. Those assertions were not removed or weakened.

### D2-03 — The Boundaries regression is not directly invoked by the checked-in GitLab pipeline

**Severity:** High; regression protection gap.

The inspected `.gitlab-ci.yml` invokes the deployment configuration checks, cleanup self-test, runtime security smoke, browser E2E, and the M9–M17 semantic integration scripts. It does not directly invoke `Test-GeordiCaptureGenerations.ps1 -Case Boundaries` (nor the separate `AuthContract` case).

Therefore, even a locally green Boundaries case would not currently be guaranteed to run in the visible CI pipeline. CI wiring is intentionally left unchanged in this audit because the current M19 checkpoint keeps CI activation blocked pending the focused regression and independent review.

### D2-04 — The full CI critical path and timeout budget remain unproven

**Severity:** High; release-readiness gap.

The M19 plan records that the GitLab sequence has not been executed end-to-end and that no full critical-path measurement exists against the 27-minute runner script timeout and 30-minute job timeout. Historical durations for individual local smokes cannot establish the actual serial CI duration, startup cost, cleanup cost, or timeout margin.

### D2-05 — CI cleanup is destructive to project-scoped runtime resources and depends on runner isolation

**Severity:** High operational risk; controlled by execution environment.

The integration job and cleanup script use Docker Compose teardown with `--remove-orphans`, remove project containers/network, and remove temporary TLS/capture material. The cleanup implementation explicitly preserves the two named M19 data volumes and checks their availability. This is not a harmless test-only operation: it must run against an isolated/dedicated Docker daemon or runner context, not a developer's shared local `geordi` stack.

No Docker command, cleanup script, TLS operation, or volume operation was executed during this audit.

### D2-06 — Several runtime evidence contracts remain incomplete independently of Boundaries

**Severity:** Blocking for M19 acceptance.

The current milestone record still identifies the nine-channel runtime scan and sanitized failure-diagnostic scan as unverified, the publishable-artifact sweep as incomplete, the detailed actuator/startup contract matrix as incomplete, and the fresh independent milestone review as outstanding. The milestone status therefore remains **M19 NOT READY — REMEDIATION REQUIRED**.

## Changes made on this branch

Only `scripts/Test-GeordiCaptureGenerations.ps1` was modified:

1. Corrected stale M10/M11/M12 source markers and added explicit checks against the current M10/M12 replacement helpers.
2. Added the M12 Collector to the synthetic boundary sequence, in the implementation's replacement order.
3. Changed the expected Collector generation count from two to three and corrected the boundary summary.

No application code, CI configuration, Compose configuration, TLS/certificates, runtime captures, or protected volumes were changed.

## Validation performed

- Read-only inspection of the current scripts and CI configuration.
- Static source-fragment comparison: all 21 revised positive/negative marker checks matched the current source.
- Manual review of the changed synthetic stage sequence and expected generation cardinalities.

## Validation not performed

- PowerShell parser execution.
- `AuthContract` or `Boundaries` execution.
- Accepted regression sequence.
- Docker/runtime tests, CI pipeline, cleanup, TLS/certificate operations, capture mutation, or protected-volume operations.

The current execution environment does not provide `pwsh`; the static comparison is not a substitute for PowerShell parsing or execution. **Gate 5 / Boundaries remains NOT PROVEN.**

## Resume sequence

1. On a Windows/PowerShell 7 environment with the correct checkout, parse `scripts/Test-GeordiCaptureGenerations.ps1`.
2. Run `Test-GeordiCaptureGenerations.ps1 -Case AuthContract`.
3. Run `Test-GeordiCaptureGenerations.ps1 -Case Boundaries`; stop on the first failure and do not weaken generation assertions to force a pass.
4. If both pass, restart the accepted regression set from its first item and stop on the first failure.
5. Obtain the fresh read-only shared-readiness review. Only a clean review and green accepted regression set can authorize the next formal gate sequence.

M19 acceptance, CI activation, M13 implementation, runtime operations, and candidate promotion remain blocked.
