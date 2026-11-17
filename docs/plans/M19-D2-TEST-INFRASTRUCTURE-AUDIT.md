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

The branch contains the D2 audit document and a modification to `scripts/Test-GeordiCaptureGenerations.ps1`:

1. Corrected stale M10/M11/M12 source markers and added explicit checks against the current M10/M12 replacement helpers.
2. Added the M12 Collector to the synthetic boundary sequence, in the implementation's replacement order.
3. Changed the expected Collector generation count from two to three and corrected the boundary summary.
4. Corrected the synthetic `negative-unsealed` handoff fixture to pass the process-identity and stop-process callbacks used by the other synthetic cases.
5. Corrected the same-container negative case to assert the implemented fail-closed contract: the duplicate container identity is rejected before a new generation is registered, and the handoff becomes `incomplete-replacement`.
6. Retained the StrictMode-safe property check for optional `absent` facts.

No application code, CI configuration, Compose configuration, TLS/certificates, runtime captures, or protected volumes were changed. The temporary diagnostic instrumentation used during local debugging was removed before the clean regression run.

## Validation performed

The following results were reported from the user's Windows PowerShell 7 checkout on 2026-11-16:

- PowerShell parser check: **PASS** after restoring the complete test file and applying the StrictMode-safe correction.
- `Test-GeordiCaptureGenerations.ps1 -Case AuthContract`: **PASS**, with `evaluation_auth_contract=PASS`; immediately queried `$LASTEXITCODE` was `0`.
- `Test-GeordiCaptureGenerations.ps1 -Case Boundaries`: completed without a visible exception and emitted both:
  - `pre_m14_generation_boundaries=PASS`
  - `pre_m14_generation_fail_closed=PASS`

The Boundaries output covered the M9–M14 synthetic stage summary and the negative cases for unsealed generation, follower mismatch, missing new generation, same container, wrong new follower, invalid order, missing capture, missing handoff, timestamp mismatch, and historical immutability.

**Historical evidence note (superseded 2026-11-16):** at the time this audit text was first written, the explicit `$LASTEXITCODE` had not yet been recorded. The later owner confirmation is now captured in the dated correction log below. The Boundaries result remains a focused local regression, not the full accepted regression sequence.

- Temporary diagnostic markers `MOCK PROCESS CHECK`, `SEAL CORE ORIGINAL FAILURE`, and `SAME-CONTAINER DIAGNOSTIC` were checked with `Select-String`; no matches were returned.
- Read-only inspection of the current scripts and CI configuration.
- Static source-fragment comparison: all 21 revised positive/negative marker checks matched the current source.
- Manual review of the changed synthetic stage sequence and expected generation cardinalities.

## Validation not performed

- Full accepted regression sequence from its first item.
- Nine-channel runtime scan and sanitized failure-diagnostic scan.
- Publishable-artifact sweep.
- Detailed actuator/startup contract matrix.
- Fresh independent milestone/shared-readiness review.
- Docker/runtime tests, GitLab pipeline end-to-end execution, cleanup, TLS/certificate operations, capture mutation, or protected-volume operations.
- Full CI critical-path timing against the configured timeout budget.

No Docker command, cleanup script, TLS operation, or volume operation was executed during this audit.

## Resume sequence

1. Capture and record the explicit exit code for the clean `Boundaries` run (expected `0`).
2. If it is `0`, restart the accepted regression set from its first item and stop on the first failure; do not weaken generation assertions to force a pass.
3. Complete the remaining non-runtime/static D2 review, including the CI invocation gap and timeout budget evidence.
4. Obtain the fresh read-only shared-readiness review. Only a clean review and green accepted regression set can authorize the next formal gate sequence.
5. Schedule runtime/CI evidence only after the required isolated runner/daemon and explicit authorization are available.

M19 acceptance, CI activation, M13 implementation, runtime operations, and candidate promotion remain blocked.


## Correction log — 2026-11-16

This section is append-only. Earlier checkpoint statements are retained as historical records; where they conflict with this dated correction, the newer evidence below is authoritative.

### D2 validation evidence correction

The owner subsequently confirmed that, immediately after the final clean execution of:

`scripts/Test-GeordiCaptureGenerations.ps1 -Case Boundaries`

the PowerShell `$LASTEXITCODE` was **0**. The two expected output markers were also observed:

- `pre_m14_generation_boundaries=PASS`
- `pre_m14_generation_fail_closed=PASS`

Accordingly, the explicit Boundaries process exit code is now **recorded as PASS / 0**. The earlier evidence limitation above is superseded; it is retained only to preserve the chronology of the audit.

### Current regression-sequence status

The focused parser, `AuthContract`, and `Boundaries` checks are reported PASS. This does **not** establish that the full accepted regression sequence passed.

The sequence was restarted from its first item and stopped at `Test-GeordiCaptureGenerations.ps1 -Case Boundaries` during the earlier attempt. Following the D2 correction, the focused Boundaries run passed with exit code 0. The complete accepted regression set has **not yet been rerun from its first item**. Its complete ordered membership is still being recovered from the repository history and supporting plans.

The worktree resume checkpoint additionally records these focused results before the stop point: M11 backend synthetic regression PASS; M12 main backend synthetic regression PASS; M12 overlap backend positive sequence and its two-boundary failure matrix PASS; M12 overlap Collector self-test PASS; AuthContract PASS; parser PASS. These are known completed checks, but the available checkpoint does not establish their exact place in the accepted sequence or prove that the list is exhaustive.

### Documentation reconciliation

- The 2026-11-16 owner-confirmed exit code supersedes the earlier statement that the Boundaries exit code was unrecorded.
- The historical 2026-10-06 checkpoint saying Boundaries assertions did not execute describes the failed attempt before D2 remediation; it is not the result of the later clean D2 run.
- The D2 audit branch still changes only this audit document and `scripts/Test-GeordiCaptureGenerations.ps1` relative to `m19`.
- The full accepted regression set, fresh independent shared-readiness review, and formal overlap 26-gate sequence remain pending in the required order.
- M19 remains **NOT READY — REMEDIATION REQUIRED**. No CI activation, runtime/Docker lifecycle, TLS/certificate operation, capture mutation, cleanup, protected-volume operation, M13 implementation, or candidate promotion is authorized by this correction.


## D2-07 — Overlap Collector SelfTest has a real Docker CLI config-render dependency

**Severity:** Medium — test-environment classification and reproducibility.

Static inspection of scripts/lib/GeordiM12OverlapCollector.ps1 found that Get-GeordiM12OverlapComposeConfiguration executes docker compose ... config --format json. Test-M12OverlapComposeIsolation and the overlap Collector failure harness use this renderer. Consequently, scripts/Test-GeordiM12OverlapCollector.ps1 -SelfTest is not wholly offline, despite using synthetic lifecycle adapters for replacement, identity, follower, readiness and cleanup.

The command renders effective Compose configuration. In the reviewed path it does not start, stop, recreate or remove containers, delete volumes, or activate CI. This finding is not evidence of a Docker lifecycle operation. It does mean that Docker CLI/Compose availability and its configuration/environment are prerequisites and must be disclosed before running the suite.

The current test script does not expose a dedicated selector for only the Compose isolation/rendering check. Its focused Case selectors cover wrapper/failure subsets and may invoke the same renderer. Do not label a focused Case as Docker-free without inspecting that exact path.

**Disposition:** keep the Collector regression as a separate config-aware caller gate. Require explicit owner approval to permit the Docker CLI config-render operation, or defer it and record the coverage gap. Do not add Docker lifecycle permission.

## D2-08 — Caller regression suites are broader than the shared callback contract

**Severity:** Medium — test-plan clarity, not an identified production defect.

The direct shared contract is isolated in scripts/Test-GeordiPostFollowerReadiness.ps1 with five cases: CallbackAbsent, Ordering, WrongFollower, ReadinessFailure and CleanupFailure. The M11, M12 backend, M12 overlap backend and M12 overlap Collector suites are caller/workflow regressions. They also cover domain-specific evidence, recovery, volume ownership, command scope, Compose isolation and production wiring.

This is a defensible layered regression strategy because the shared seam is integrated into four authorized consumers. The clarity problem arose when those aggregates were presented as if they were homogeneous callback tests or as one wholly offline set.

**Disposition:** classify evidence by layer: shared seam; M11 caller; M12 backend caller; M12 overlap backend caller; M12 overlap Collector caller; capture-generation/authentication boundaries; static scope and independent review. Keep M10, fixture-transfer 18-gate/A–S, M11→M12 19-gate remediation and formal overlap 26-gate validation separate.

## Revised validation disposition — 2026-11-16

The proposed order is now:
1. Read-only branch/worktree and scope preconditions.
2. Parser checks and the five direct shared-seam cases, individually and fail-fast.
3. Strictly synthetic caller regressions: M11, M12 backend, M12 overlap backend.
4. Capture-generation AuthContract, then Boundaries.
5. Separately approved M12 overlap Collector SelfTest, acknowledging its Docker CLI config-render dependency but no Docker lifecycle operation.
6. Read-only scope review and fresh independent review.

No test was executed during this static review. Temporary-root cleanup in the inspected harnesses targets generated test roots/files. The reviewed synthetic caller paths use injected adapters for process, volume and replacement behavior; no Docker lifecycle operation, protected-volume operation, real capture mutation, CI activation, TLS operation or runtime action was found in those paths.

The complete reconstructed sequence remains NOT RUN. Prior focused PASS records are unchanged and are not promoted to a full-suite result. M19 remains NOT READY — REMEDIATION REQUIRED.
