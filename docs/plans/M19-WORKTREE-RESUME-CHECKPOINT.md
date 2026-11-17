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


## 2026-11-16 — Second-pass repository-history findings

The second read-only pass examined the D2 branch commits and the relevant M19 plans.

### What the repository history establishes

- Before the documentation reconciliation commits, `d2/audit-boundaries-fix` was 9 commits ahead of `m19`, with no commits behind.
- Those nine commits consist of seven test-harness changes to `scripts/Test-GeordiCaptureGenerations.ps1` and two D2 audit-document commits. They do not contain an earlier revision of the accepted-regression inventory or a sequence manifest.
- The `m19` base commit is exposed as a full-tree snapshot (its commit change listing reports the repository files as additions), rather than a useful incremental history of the prior planning conversation. The available branch history therefore does not provide earlier versions of the M19 planning documents from which to recover a lost ordered list.

### What the contemporaneous plans establish

- `EXECPLAN-M19-POST-FOLLOWER-READINESS.md` defines the phase ordering — parser/micro checks → accepted regression set → independent review → formal overlap 26-gate sequence — but does not enumerate the accepted set.
- This checkpoint records the earlier stop at `Boundaries` and several focused PASS results, but does not give the complete ordered list.
- `MILESTONE-019.md` records related focused evidence, including M11 synthetic generation/volume tests, M11 propagation-isolation, M11 final-evidence and VM-identity tests, seven focused M10 replacement cases, M12 Collector replacement self-test, parser checks, and `git diff --check`. It does not identify these as the complete accepted regression set or specify their accepted execution order.
- The M10, M11, M12 backend, M12 overlap Collector, and M11→M12 fixture-transfer ExecPlans each define their own scoped validation. Those scoped validations must not be silently merged into one historical accepted sequence. In particular, the fixture-transfer plan's 18 focused gates and A–S consumer matrix are a separate validation unit.

### Second-pass conclusion

The exact historical membership and order of the post-follower accepted regression set are **not recoverable from the currently available branch history and checked-in planning documents**. This is a bounded conclusion about the evidence inspected, not proof that no external transcript, local reflog, untracked file, or earlier workspace copy exists.

Do not label a proposed list as the original accepted sequence. The next valid step is to prepare a clearly labelled **reconstructed regression sequence** from the scoped ExecPlans and known checkpointed PASS evidence, identify every item as previously passed / not yet rerun / pending, and submit that reconstruction for owner approval before execution.


## 2026-11-16 — Post-follower regression architecture review

This addendum supersedes the previous generic instruction to execute one reconstructed offline/static sequence. It preserves all historical checkpoints and prior PASS records.

### Reconstructed implementation intent

The shared AfterFollowerValidated seam enforces this order: container replacement and new identity resolution; follower startup; validation of returned and persisted process/container/service/project binding; publication of that binding; readiness callback; handoff completion. Callback failure leaves truthful incomplete state, attempts cleanup, preserves the primary error and sealed history. Callback omission preserves legacy behavior.

The test code reflects a layered strategy:
- Direct shared contract: five cases in Test-GeordiPostFollowerReadiness.ps1.
- M11 caller/workflow regression: Test-GeordiM11BackendGenerations.ps1 -SelfTest.
- M12 backend caller/workflow regression: Test-GeordiM12BackendGenerations.ps1 -Case SelfTest.
- M12 overlap backend caller/workflow regression: Test-GeordiM12OverlapBackendVmGenerations.ps1 -Case SelfTest.
- M12 overlap Collector caller/workflow regression: Test-GeordiM12OverlapCollector.ps1 -SelfTest.
- Adjacent capture-generation/authentication contracts: Test-GeordiCaptureGenerations.ps1 -Case AuthContract and -Case Boundaries.
- Static scope review and independent review.

The four caller suites are broader than the callback contract. They protect domain invariants such as evidence publication, recovery, volume ownership, command scope, Compose isolation and production wiring. Report them as caller/workflow regressions, not as pure callback unit tests.

### Safety classification correction

The reviewed M11, M12 backend and M12 overlap backend synthetic paths use generated temporary roots and injected replacement/process/readiness/volume adapters. Their reviewed SelfTest paths inspect command arguments rather than executing Docker lifecycle operations.

The M12 overlap Collector path has one important exception: Get-GeordiM12OverlapComposeConfiguration executes the real Docker CLI with docker compose ... config --format json. This renders configuration only; it does not start, stop, recreate or remove containers, delete volumes, or activate CI. The Collector SelfTest is therefore not wholly offline, even though its lifecycle callbacks are synthetic. The current script has no dedicated selector for only the Compose isolation/rendering portion.

Temporary Remove-Item calls inspected in these test harnesses target generated temporary roots or files beneath them. No reviewed synthetic test path targets protected M19 volumes or real capture roots.

### Revised proposed resume sequence — not historical

1. Read-only branch/worktree/diff preconditions; preserve all existing state.
2. Parse affected scripts and helpers; run the five direct shared-seam cases individually, fail-fast.
3. Run strictly synthetic caller regressions: M11, M12 backend, M12 overlap backend.
4. Run AuthContract, then Boundaries, with immediate exit-code checks.
5. Separately obtain owner approval for M12 overlap Collector SelfTest's Docker CLI config-render dependency. Either permit that configuration-render command only or defer the suite and record the coverage gap. No Docker lifecycle permission is implied.
6. Perform read-only scope review and obtain a fresh independent review.

Do not add M10 seven-case replacement, fixture-transfer 18-gate/A–S, M11→M12 19-gate remediation or formal overlap 26-gate validation to this focused sequence. The 26-gate sequence remains conditional on a green approved focused set and clean independent review.

### Execution status and milestone

This was a static repository review and documentation update only. No test, parser, Docker command, Compose command, runtime operation, cleanup, capture mutation, CI activation, TLS/certificate operation or protected-volume operation was executed in this step. Prior focused PASS results remain historical evidence; the complete reconstructed sequence remains NOT RUN. M19 remains NOT READY — REMEDIATION REQUIRED.


## Addendum — M12 overlap Collector Compose validation separation — 2026-11-16

The D2 branch now separates the overlap Collector Compose validation into:
- `-SelfTest`: injected executor contract plus synthetic configuration invariants and synthetic caller/workflow regressions; intended to be Docker-independent.
- `-ComposeIntegration`: explicit real Docker CLI `config --format json` rendering for normal and replacement/isolation configurations, followed by the same isolation assertions.
- `-Case`: existing focused synthetic caller/failure cases.

The selectors `-SelfTest` and `-ComposeIntegration` are mutually exclusive. No test, parser, Docker, Compose, lifecycle, runtime, cleanup, TLS, capture or protected-volume operation was executed during implementation. The new implementation still requires static review. Do not infer a PASS result from the code change. Full accepted regression sequence remains NOT RUN; M19 remains **NOT READY — REMEDIATION REQUIRED**.


### D2-09 static review update — 2026-11-16

Read-only review of the final source confirms that synthetic harness renderers use the synthetic fixture provider, `-SelfTest` exercises the injected Compose executor and synthetic configuration invariants, and `-ComposeIntegration` is the only selector that invokes the real Docker CLI config renderer. The integration selector is mutually exclusive with `-SelfTest` and `-Case`.

No parser or test was executed. The implementation is statically reviewed but **not execution-verified**. Do not treat this as a PASS. Docker CLI config rendering remains a separate operation requiring its own authorization; lifecycle, runtime, cleanup, TLS, capture and protected-volume operations remain outside scope.


### Branch-scope correction after D2-09 — 2026-11-16

The current comparison `m19...d2/audit-boundaries-fix` reports 31 commits ahead, zero behind, and seven changed paths. In addition to the four documentation paths and the existing `scripts/Test-GeordiCaptureGenerations.ps1` correction, D2-09 adds:
- `scripts/Test-GeordiM12OverlapCollector.ps1`
- `scripts/lib/GeordiM12OverlapCollector.ps1`

No application source, CI, Compose YAML, TLS/certificates, runtime captures or protected-volume definitions are changed. Earlier five-path snapshots remain historical and are superseded by this branch-scope correction.

## 2026-11-16 — D2-10 M12 overlap Collector B+C execution checkpoint

This append-only checkpoint records the owner-supplied execution evidence for the D2-09 separation. It does not alter prior historical entries or imply completion of the full accepted regression sequence.

### Executed and reported results

1. PowerShell parser:
   - `scripts/lib/GeordiM12OverlapCollector.ps1` — **PASS**.
   - `scripts/Test-GeordiM12OverlapCollector.ps1` — **PASS**.
2. `Test-GeordiM12OverlapCollector.ps1 -SelfTest` — **PASS**. The owner-supplied output reports the injected executor contract, synthetic normal/isolated configuration invariants, seven restart edges versus zero, configuration equivalence, protected M19 mount preservation, eight propagation-negative cases, command scope, handoff/startup ordering, wrapper failures, wrong-follower boundaries, and second-handoff failure scenarios. The final marker states `runtime=NOT_RUN`, `ci=unchanged`, and `backend_generation=deferred`. The immediate `$LASTEXITCODE` guard did not throw.
3. `Test-GeordiM12OverlapCollector.ps1 -ComposeIntegration` — **PASS**. The owner-supplied output reports real Compose config rendering for normal and isolated configurations, the same isolation/equivalence/protected-mount assertions, and the eight-case negative matrix. Its final marker states `docker_operation=config_render_only` and `lifecycle=NOT_INVOKED`.

### Scope and remaining work

The recorded Compose integration is configuration rendering only. No Docker lifecycle, runtime, cleanup, protected-volume operation, CI activation, TLS/certificate operation, or capture mutation is reported as part of these runs.

B+C validation is now execution-verified by the supplied focused output. The complete accepted regression sequence remains **NOT RUN** and must not be inferred from these focused PASS results. The sequence's historical exact membership/order remains unrecovered; any proposed sequence must remain labelled `RECONSTRUCTED — NOT HISTORICAL` and be submitted for owner approval before execution.

Next sequence remains:
1. Complete the evidence-backed regression reconstruction and obtain owner approval.
2. Execute only the approved regression sequence, fail-fast.
3. Obtain the fresh independent read-only shared-readiness review.
4. Consider the formal overlap 26-gate sequence only after the approved regression sequence is fully green and the independent review is clean.

M19 remains **NOT READY — REMEDIATION REQUIRED**. M13, Gate 5 promotion/acceptance, CI activation, runtime validation, candidate promotion, and M19 acceptance remain blocked.

## 2026-11-16 — D2-11 finalized reconstructed regression resume point

The full proposed sequence is documented in `docs/plans/M19-ACCEPTED-REGRESSION-RECONSTRUCTION.md`, Section 11. It is **RECONSTRUCTED — NOT HISTORICAL**, not recovered original membership/order.

### Proposed order

P0 read-only branch/worktree preconditions → P1 parser (eight directly involved files) → P2 five shared-seam cases → P3 M11/M12/M12 overlap-backend caller SelfTests → P4 AuthContract then Boundaries → P5 overlap Collector synthetic `-SelfTest` → P6 separately approved overlap Collector `-ComposeIntegration` (Docker CLI config render only) → P7 read-only diff/scope → P8 fresh independent review.

### Evidence already supplied

- Parser for the D2 overlap library and test script: PASS.
- Overlap Collector `-SelfTest`: PASS; synthetic executor/configuration fixtures, runtime NOT_RUN, CI unchanged.
- Overlap Collector `-ComposeIntegration`: PASS; normal and isolated Compose config renders, protected M19 mount configuration unchanged, eight negative propagation cases, lifecycle NOT_INVOKED.
- Existing focused PASS records for shared microtests, M11, M12 backend, overlap backend, AuthContract and corrected Boundaries remain prior evidence only.

### Required next action

Owner review/approval of the reconstructed P0–P8 membership and order. No full-sequence tests are authorized by this documentation update. All prior focused PASS items must be rerun fail-fast from P0 to claim the reconstructed set green. P6 must receive fresh narrow approval if it is to be rerun.

Keep M10 seven-case, fixture-transfer 18-gate/A–S, M11→M12 19-gate remediation and formal overlap 26-gate validation separate. Obtain P8 only after P0–P7 are green. M19 remains **NOT READY — REMEDIATION REQUIRED**; M13, Gate 5, CI activation, runtime operations, candidate promotion and M19 acceptance remain blocked.
