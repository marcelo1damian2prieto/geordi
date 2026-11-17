# ExecPlan: M19 post-follower readiness ordering

## Status

In progress. Scope is limited to the optional shared `AfterFollowerValidated` seam and the four owner-authorized callers: M11 backend, M12 main backend, M12 overlap backend, and M12 overlap Collector. M10, M13, runtime/Docker lifecycle, CI activation, TLS, captures, and candidate acceptance are excluded. Preserve all existing dirty worktree changes.

## Confirmed mechanism

`Start-GeordiCaptureGeneration` currently invokes `StartFollower`, validates the returned process and persisted process record against the exact service/container/project, publishes the validated follower identity, then completes a pending handoff. M11, M12 main backend, M12 overlap backend, and M12 overlap Collector currently perform service readiness inside the `StartFollower` callback, so readiness can succeed before the shared exact-binding validation. The shared helper already has incomplete generation/handoff states and owns follower cleanup on post-start failures.

## Plan

1. Add shared helper tests first for callback-absent compatibility, positive event order, wrong-follower rejection before callback, callback failure, cleanup failure precedence, and immutable old history.
2. Add optional `AfterFollowerValidated` parameters to `Start-GeordiCaptureGeneration`, `Invoke-GeordiCaptureHandoffReplacement`, and the controlled M12 Collector wrapper. Invoke the callback only after process-record validation/publication and before handoff completion. Preserve the primary failure while attempting follower cleanup; retain existing incomplete states.
3. Move readiness callbacks out of the four authorized follower starters and into the shared seam. Do not alter M10 or unrelated production callers.
4. Add/complete focused M11, M12 main, M12 overlap backend boundary failure matrices, overlap Collector ordering/second-handoff-history coverage, and CI nonactivation static assertions only.
5. Run the requested fail-fast parser/micro checks, then accepted regression set, then independent read-only review. Only if review is clean, restart the formal overlap 26-gate sequence and obtain a fresh final review.

## Acceptance and stop conditions

- Wrong follower never invokes readiness; callback runs after exact binding and before handoff completion.
- Callback failure leaves truthful incomplete state, attempts cleanup, preserves the primary exception, and does not mutate sealed history.
- Omitting the callback preserves existing caller behavior, including M10 and base M12 Collector.
- The overlap Collector graph remains C0→HC1→C1→HC2→C2, and failure in HC2 does not alter accepted HC1/C0 history or fabricate C2.
- Real `.gitlab-ci.yml` remains unchanged; no runtime or Docker lifecycle operation occurs.
- Stop at the first failed gate. Do not proceed to M13, Gate 5, CI activation, runtime validation, or M19 acceptance.

## Initial production-caller inventory

- Affected and authorized: `Invoke-GeordiM11BackendGenerationReplacement`; M12 main backend replacement; M12 overlap backend handoff; `Invoke-GeordiM12OverlapCollectorReplacement`.
- Unaffected: M10 passes `StartFollower` directly without readiness; the base M12 Collector helper performs readiness in its replacement action before follower startup; M14 does readiness at stage orchestration rather than inside a shared handoff `StartFollower`; Finalize/restoration passes `StartFollower` directly without a readiness callback.
- No other production caller with the same readiness-inside-`StartFollower` pattern was found.


## Execution evidence and regression-sequence recovery — 2026-11-16

The following focused results are recorded from the current workstream/checkpoint evidence:

- Shared post-follower microtests: PASS.
- M11 backend synthetic regression: PASS.
- M12 main backend synthetic regression: PASS.
- M12 overlap backend positive sequence and 12-case failure matrix at each of two boundaries: PASS.
- M12 overlap Collector ordering/second-handoff-history self-test: PASS.
- Capture-generation `AuthContract`: PASS; six negative controls rejected.
- Capture-generation PowerShell parser: PASS.
- Capture-generation `Boundaries`: PASS after D2 test-only corrections; owner-confirmed `$LASTEXITCODE = 0`, with both boundary PASS markers observed.

These focused results do not establish that the full accepted regression set passed. The resume checkpoint records an earlier accepted-sequence attempt stopping at `Boundaries`; after the D2 correction, the full sequence has not yet been rerun from its first item.

**Open item:** recover the exact membership and order of the accepted regression set from repository history and contemporaneous plans. Do not infer it from the `ValidateSet` cases in `Test-GeordiCaptureGenerations.ps1`, nor conflate it with the formal overlap 26-gate sequence or the separate M11→M12 19-gate remediation sequence. If the original order cannot be substantiated, label any proposed sequence as a new reconstruction and obtain owner approval before execution.

The required next sequence remains: recover/approve accepted regression order → run it fail-fast → fresh independent read-only review → only if clean, formal overlap 26-gate sequence → fresh final review. M19 remains NOT READY; no runtime/Docker lifecycle, CI activation, TLS, capture mutation, cleanup, protected-volume operation, M13, or candidate promotion is authorized here.


## Second-pass history finding — 2026-11-16

The D2 branch history was inspected commit by commit. Its nine commits ahead of `m19` before the documentation addenda contain seven changes to `Test-GeordiCaptureGenerations.ps1` and two D2 audit-document commits; none supplies an earlier accepted-regression inventory. The `m19` base is exposed as a full-tree snapshot, so the available Git history does not provide earlier incremental revisions of the planning documents.

The post-follower plan itself specifies the required phase order but not the commands or complete membership of the accepted regression set. The resume checkpoint and milestone record contain individual prior PASS results and scoped validation descriptions, not a canonical ordered list. The separate M10/M11/M12/overlap/fixture-transfer ExecPlans define independent validation slices and cannot be treated as one accepted set without an explicit reconstruction.

**Conclusion:** the original accepted regression set's exact membership and order are not recoverable from the currently available repository history and checked-in documents. This does not rule out an external transcript, local reflog, untracked file, or earlier workspace copy.

**Next action:** produce a new artifact labelled `RECONSTRUCTED — NOT HISTORICAL`, derived from the scoped ExecPlans and checkpoint evidence. For each proposed item, record its source, exact command/case, prior evidence status (PASS / failed attempt / not run / unknown), and whether it must be rerun. Present that sequence for owner approval before executing it. Do not infer it from the harness `ValidateSet`, the overlap 26-gate sequence, or the M11→M12 19-gate sequence.


## Test-entry-point recovery addendum — 2026-11-16

The follow-up repository inspection recovered the exact focused test entry points. This supersedes the earlier statement that the paths/invocations were unknown; it does not establish the historical accepted-set order and does not authorize execution.

- Shared seam: `scripts/Test-GeordiPostFollowerReadiness.ps1`, cases `CallbackAbsent`, `Ordering`, `WrongFollower`, `ReadinessFailure`, and `CleanupFailure`.
- M11 caller: `scripts/Test-GeordiM11BackendGenerations.ps1 -SelfTest`.
- M12 main backend caller: `scripts/Test-GeordiM12BackendGenerations.ps1 -Case SelfTest`.
- M12 overlap backend caller: `scripts/Test-GeordiM12OverlapBackendVmGenerations.ps1 -Case SelfTest`.
- M12 overlap Collector caller: `scripts/Test-GeordiM12OverlapCollector.ps1 -SelfTest`.
- Capture-generation contract: `scripts/Test-GeordiCaptureGenerations.ps1 -Case AuthContract`, then `-Case Boundaries`.

The direct seam test is narrow. The four caller self-tests are broader compatibility suites: they also exercise volume ownership, persisted metric evidence, recovery/sequence invariants, and static wiring. They should be identified as caller-level regression coverage, not as pure callback unit tests. M10, the separate fixture-transfer 18-gate/A–S matrix, the M11→M12 19-gate remediation, and the formal overlap 26-gate sequence remain separate.

The proposed integrated offline proof and rationale are recorded in `docs/plans/M19-ACCEPTED-REGRESSION-RECONSTRUCTION.md`, Addendum 9. No test was executed during this discovery pass. Owner approval remains required before running the reconstructed sequence.


## Test architecture and revised validation order — 2026-11-16

This addendum supersedes any implication in the earlier plan that all four caller self-tests are uniformly offline or that they are all direct tests of the callback.

### Intent and test layers

The implementation's shared invariant is: replace container → resolve new identity → start follower → validate returned and persisted process/container/service/project binding → publish binding → invoke readiness → complete handoff. Callback failure must leave truthful incomplete state, attempt follower cleanup, preserve the primary exception and sealed history; callback omission preserves legacy behavior.

The regression architecture is layered:

1. **Shared seam (direct contract):** scripts/Test-GeordiPostFollowerReadiness.ps1, cases CallbackAbsent, Ordering, WrongFollower, ReadinessFailure, CleanupFailure. This is the narrowest proof of the shared callback contract.
2. **M11 caller regression:** scripts/Test-GeordiM11BackendGenerations.ps1 -SelfTest. Covers three synthetic boundaries, failure matrix, dedicated fixture-volume removal safety and production wiring.
3. **M12 backend caller regression:** scripts/Test-GeordiM12BackendGenerations.ps1 -Case SelfTest. Covers backend handoffs plus reset-evidence publication/reuse/integrity/races, metric phases, recovery, volume/command scope and transferred-path wiring. This is broader than callback behavior.
4. **M12 overlap backend caller regression:** scripts/Test-GeordiM12OverlapBackendVmGenerations.ps1 -Case SelfTest. Covers entry state, VM evidence, volume ownership, backend handoffs, two 12-case fault matrices, full sequence and cross-service failure.
5. **M12 overlap Collector caller regression:** scripts/Test-GeordiM12OverlapCollector.ps1 -SelfTest. Covers source map, CI nonactivation, Compose restart-propagation isolation, command scope, sequential handoffs and failure matrices.
6. **Capture-generation/authentication contract:** Test-GeordiCaptureGenerations.ps1 -Case AuthContract and -Case Boundaries, plus parser checks. These are adjacent capture-generation/authentication boundaries, not direct callback tests.
7. **Static scope and independent review:** read-only diff, source and safety review.

The four caller suites are compatibility/workflow regressions. Their broader checks are intentional protection of the four authorized consumers, but they must not be described as pure callback unit tests.

### Execution-boundary finding

The static review found that Layers 1–4 above use synthetic identities and injected replacement, follower, readiness, process and volume adapters; their reviewed paths do not invoke Docker lifecycle operations. Temporary cleanup targets generated temporary roots/files.

**Exception:** the overlap Collector library's Get-GeordiM12OverlapComposeConfiguration invokes the real Docker CLI using docker compose ... config --format json. That is configuration rendering, not container lifecycle: it does not start, stop, recreate or remove containers, remove volumes, or activate CI. Nevertheless, it is a real external CLI dependency, so the overlap Collector SelfTest is not wholly offline. The current script has no dedicated selector for only the Compose isolation/rendering portion; do not claim any focused Case is Docker-free without tracing that exact path.

### Revised proposed order — not historical

- **Gate 0:** read-only branch/worktree/diff preconditions; preserve changes.
- **Gate 1:** parser checks, then the five shared-seam cases individually, fail-fast.
- **Gate 2:** strictly synthetic caller regressions in order M11, M12 backend, M12 overlap backend.
- **Gate 3:** AuthContract, then Boundaries, with immediate exit-code checks.
- **Gate 4:** separately decide whether to permit M12 overlap Collector SelfTest's Docker CLI config-render dependency. Either run it with that narrow permission or defer it and record the coverage gap. No Docker lifecycle permission is implied.
- **Gate 5:** read-only scope check and fresh independent review.

Stop at the first failure. Keep M10's seven-case suite, fixture-transfer 18-gate/A–S capability, M11→M12 19-gate remediation, and formal overlap 26-gate sequence separate. The 26-gate sequence remains conditional on a green approved focused set and clean independent review.

### Execution status

This addendum records static inspection only. No test was executed. Prior focused PASS results remain historical evidence; the complete reconstructed sequence has not been rerun end-to-end. Owner approval is still required before any execution, including the config-rendering dependency in Gate 4.
