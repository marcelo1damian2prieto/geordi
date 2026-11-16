# M19 Worktree Resume Checkpoint

Updated: 2026-10-02 (America/Buenos_Aires)

## Authoritative status

- Milestone: `M19 NOT READY — REMEDIATION REQUIRED`
- Candidate `6fe4e83ffaf7418ebcc7015a4c176b61`: diagnostic-only
- Source-to-candidate provenance: unproven
- Runtime: stopped; `.runtime/m19` still exists
- Git HEAD: `2601a4ee63924e843a50dc8940a8e193709e2f5b`
- Worktree: 71 modified entries and 66 untracked entries; preserve all changes
- Geordi containers: 13 present, all exited
- Protected volumes present: `geordi_m19-alert-lifecycle-data`, `geordi_m19-victoriametrics-data`

## Latest focused timestamp work

The initial rejection was `TIMESTAMP_TYPE_NORMALIZATION_DEFECT`: JSON timestamps were materialized as `System.DateTime` with `Kind=Local`, then cast to localized strings. The normalizer now converts `DateTimeOffset`, safe UTC/local `DateTime`, and canonical RFC3339 strings directly to UTC; it rejects `DateTimeKind.Unspecified`, missing, empty, and malformed values.

No new manifest field or fallback timestamp was added. Temporary diagnostic output was removed.

A bounded synthetic diagnostic then proved a second mismatch: for a measured interval of 306.694 ms, producer cast-to-`[long]` declared 307 ms while validator floor recomputation returned 306 ms. The producer now computes floor from elapsed ticks, matching the validator deterministically. The diagnostic output was removed.

Focused parser for `scripts/lib/GeordiCaptureGenerations.ps1` and `scripts/Test-GeordiCaptureGenerations.ps1`: **PASS** after the final changes.

Focused `HandoffTimestamps`: **PASS** after the final changes. The production-generated baseline passes; the test covers zero gap, bounded positive gap, declaration mismatch, actual gap over maximum, timestamp-only tampering, unsupported overlap, reversed/invalid chronology, duplicated source-timestamp mismatch, malformed/missing timestamps, and offset-equivalent instants.

## Exact resume point

1. Preserve the current dirty worktree; do not reset, stash, clean, commit, or push.
2. Focused timestamp remediation is proven by parser and `HandoffTimestamps` only.
3. Ordered offline validation resumed: Gates 1–4 passed (`StreamsEmpty`, `StreamsOutput`, `StreamsIntegrity`, `HandoffTimestamps`).
4. Stopped at Gate 5. `Boundaries` is listed in `Test-GeordiCaptureGenerations.ps1`'s `ValidateSet` but has no corresponding switch branch, and no separate pre-M14 generation-boundary self-test was found. Gate 5 proof is unavailable; Gates 6–17 were not run.
5. Add/identify the required synthetic pre-M14 boundary regression only after owner review, then resume at Gate 5. Do not skip to later gates.

## Prohibited while resuming

Do not start/stop/remove containers, run M14 or Finalize runtime, run cleanup, modify TLS/certificates, modify captures, or touch either protected volume. Do not run CI, create a candidate, or begin M20. Do not update milestone acceptance status.

The status was inventoried read-only before shutdown: all 13 listed Geordi containers were exited; both protected volumes existed; `.runtime/m19` existed. No cleanup was performed.

## 2026-10-02 — M11 Gate 5 investigation checkpoint

M10 backend remains owner-accepted. M12 Collector remains owner-accepted. The shared replacement callback is effect-only, suppresses callback success output, propagates terminating failures, and returns exactly one `generationId`; M12 compatibility was previously verified.

M11 implementation was inspected in `scripts/verify-notification-delivery.ps1` and `scripts/Capture-GeordiM19Generation.ps1`. The read-only effective Compose configuration rendered successfully from `compose.yaml`, `compose.m19.yaml`, and `compose.m11.yaml`.

M11 currently has a joint backend/VictoriaMetrics reset boundary: it captures `m11-reset`, runs `compose rm -sf backend victoriametrics`, removes only the two label-verified M11 fixture volumes, then runs one `compose up -d --force-recreate victoriametrics backend`. Both services therefore require new container IDs at that boundary. VictoriaMetrics evidence is persisted-metric snapshots/ledger, not a log follower. Backend's primary evidence is the exact-container generation follower; the existing `m11-reset`/`m11-final` Compose log snapshots are supplemental and do not seal that follower.

Two blockers prevent M11 integration:

1. **`M11_SAME_CONTAINER_RESTART_BOUNDARY`** — after its delivery assertions, M11 captures a backend snapshot, then performs `compose stop backend`, `compose start backend`, and later `compose restart --no-deps backend`. Those operations keep the same container identity. The current generation model is container-ID based, and follower continuity across these stop/start/restart operations is not proven.
2. **`M11_REPLACEMENT_PROPAGATION_REQUIRES_ISOLATION`** — effective config has zero `restart: true` reverse dependents for backend, but VictoriaMetrics has two: backend and `otel-collector`. `otel-collector` is capture-required. Compose documents that a dependent with `restart: true` restarts after an explicit Compose update to its dependency. No isolation overlay was added or tested.

The protected M19 volumes were not targeted by the inspected M11 volume-removal commands. The read-only config render and volume mapping passed. No source or documentation changes were made in this investigation; no runtime Docker operations, parser, M11 tests, cleanup, or independent review ran.

**Resume point:** owner review must resolve the backend same-container restart evidence model and the VictoriaMetrics-to-Collector restart propagation before implementing M11. Do not implement M11 until both are resolved. Then resume the focused M11 Gate 5 slice only; do not continue to Gates 6–17. Keep candidate `6fe4e83ffaf7418ebcc7015a4c176b61` diagnostic-only and preserve the dirty worktree, existing captures, and protected volumes.

## 2026-10-06 — Shared post-follower readiness and Boundaries auth checkpoint

This section supersedes older resume instructions above when they conflict with the current shared-readiness work. Preserve the existing dirty worktree exactly; no reset, stash, clean, commit, or push.

### Current scope and implementation

The shared `AfterFollowerValidated` callback seam is implemented in `scripts/lib/GeordiCaptureGenerations.ps1`. It runs after both returned and persisted follower identity, service, project, and container bindings validate, and before handoff completion. A callback failure leaves an incomplete handoff, marks the new generation incomplete, attempts follower cleanup, propagates the primary failure, and records only cleanup exception type as secondary metadata. Callback omission preserves existing behavior.

Authorized migrations are present for M11 backend, M12 main backend, M12 overlap backend, and M12 overlap Collector. The controlled M12 Collector helper has an optional callback forwarding parameter. M10 was not migrated. `.gitlab-ci.yml` was not changed and overlap activation remains opt-in.

`scripts/Test-GeordiCaptureGenerations.ps1` was changed to remove the obsolete `Invoke-GeordiAuthenticatedRequest` literal precondition from `Boundaries` and add a separate `AuthContract` AST check. That test traces the evaluation smoke's dot-source, `REGRESSION` authentication initialization, request wrappers, trusted authenticated helper, Bearer header construction, and protected lifecycle POST. Six negative controls cover comment-only import, unused helper, raw protected request, helper name as string, anonymous helper substitution, and protected mutation bypass. Two test defects were found and corrected: the dot-source AST has a `ParenExpressionAst` as its command element, and the bypass mutation initially used a nonmatching escaped source pattern.

### Latest validation evidence

- Shared post-follower microtests: ordering, wrong follower, readiness failure, cleanup failure precedence, and callback absent all **PASS**.
- M11 backend synthetic regression: **PASS**.
- M12 main backend synthetic regression: **PASS**.
- M12 overlap backend positive sequence: **PASS**; failure matrix: 12 cases at each of two boundaries **PASS**.
- M12 overlap Collector self-test: **PASS**, including config-only normal/isolated Compose renders, propagation 7→0, both wrong-follower boundaries, readiness and cleanup failures, and `C0→HC1→C1→HC2→C2`.
- `Test-GeordiCaptureGenerations.ps1 -Case AuthContract`: **PASS**; all six negative controls rejected.
- Parser for `Test-GeordiCaptureGenerations.ps1`: **PASS**.
- The accepted-regression sequence was restarted once, then stopped at `Test-GeordiCaptureGenerations.ps1 -Case Boundaries`. After removing the stale auth symbol check, its next source-text precondition failed: expected markers in `verify-alert-lifecycle.ps1` were not found. The boundary lifecycle assertions did not execute. Do not treat Gate 5/Boundaries as passing.
- `git diff --check`, M10 regression, the rest of the accepted regression set, independent reviews, overlap gates 1–26, and final review are **NOT RUN** after this stop point.

### Resume point

The auth mismatch is classified `BOUNDARIES_AUTH_HELPER_SYMBOL_ASSERTION_STALE`; source inspection and the separate AST test demonstrate the current authenticated path. The current blocker is a further brittle source-marker precondition in `Boundaries`. On resumption, inspect that exact marker against the authoritative M10 implementation before editing. Do not weaken or skip the generation assertions. If the marker is stale, make only a test-side semantic correction, parse the file, and execute the focused authentication and boundary checks. Stop on the first failure.

Only after the focused checks pass, restart the accepted regression set from its first item. Then request the fresh read-only shared-readiness review. The formal overlap 26-gate run and final overlap review remain conditional on a clean focused review and a fully green accepted regression set.

### Safety and status

- M19: `M19 NOT READY — REMEDIATION REQUIRED`.
- Candidate `6fe4e83ffaf7418ebcc7015a4c176b61`: diagnostic-only; source-to-candidate provenance unproven.
- M13 and Gate 5 remain blocked; do not activate CI, implement M13, or promote the candidate.
- No runtime smoke, Docker lifecycle, TLS/certificate operation, capture mutation, cleanup, or protected-volume operation was performed during this work. CI remains unchanged. Protected M19 volumes must remain untouched.


## 2026-11-16 — D2 Boundaries correction and current resume state

This dated addendum preserves the earlier checkpoints as historical evidence. It supersedes conflicting earlier statements only for the specific facts corrected below.

### D2 Boundaries result

The later D2 test-harness correction updated stale M10/M11/M12 source markers, represented the M12 Collector replacement in the synthetic generation sequence, corrected the Collector generation cardinality to three, and repaired the synthetic negative fixtures without changing production scripts.

The owner confirmed the final clean execution of `Test-GeordiCaptureGenerations.ps1 -Case Boundaries` returned **`$LASTEXITCODE = 0`**, with both `pre_m14_generation_boundaries=PASS` and `pre_m14_generation_fail_closed=PASS` observed.

Therefore, the 2026-10-06 statement that the Boundaries lifecycle assertions did not execute remains accurate for that failed attempt, but it is superseded as the current status by the later clean D2 PASS. The earlier statement that the exit code was unrecorded is also superseded.

### Known focused checks before/around the accepted-sequence stop

The checkpointed evidence records:

- Shared post-follower microtests: ordering, wrong follower, readiness failure, cleanup failure precedence, callback absent — PASS.
- M11 backend synthetic regression — PASS.
- M12 main backend synthetic regression — PASS.
- M12 overlap backend positive sequence and 12-case failure matrix at each of two boundaries — PASS.
- M12 overlap Collector self-test, including ordering and second-handoff history — PASS.
- `Test-GeordiCaptureGenerations.ps1 -Case AuthContract` — PASS; six negative controls rejected.
- PowerShell parser for `Test-GeordiCaptureGenerations.ps1` — PASS.
- `Test-GeordiCaptureGenerations.ps1 -Case Boundaries` after D2 correction — PASS; explicit exit code 0.

These results are not presented as a complete ordered accepted regression set. The historical checkpoint records that the accepted sequence had been restarted and stopped at Boundaries before the D2 correction; the complete sequence still needs to be restarted from its first item after the focused corrections. Exact membership and order remain under investigation.

### Current resume order

1. Continue read-only repository-history investigation to recover the exact accepted regression set and order.
2. Once the sequence is recovered—or formally declared unrecoverable—present the evidence-backed sequence for owner approval before executing the full set.
3. Execute only the approved offline/static regression sequence, fail-fast, stopping at the first failure.
4. Obtain the fresh independent read-only shared-readiness review.
5. Only if the regression set is fully green and the review is clean, consider the formal overlap 26-gate sequence and a fresh final review.

### Safety and milestone status

The D2 branch remains isolated from `m19`. No production code, CI configuration, Compose configuration, TLS/certificates, runtime captures, or protected volumes were changed by D2. No Docker lifecycle, runtime, cleanup, TLS/certificate, capture mutation, or protected-volume operation was performed.

M13, Gate 5 promotion/acceptance, CI activation, runtime validation, candidate promotion, and M19 acceptance remain blocked. Overall status remains **M19 NOT READY — REMEDIATION REQUIRED**.
