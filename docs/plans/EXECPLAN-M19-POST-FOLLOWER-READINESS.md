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
