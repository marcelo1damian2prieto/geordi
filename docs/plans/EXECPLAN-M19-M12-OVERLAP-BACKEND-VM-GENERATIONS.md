# ExecPlan: M12 overlap backend and VictoriaMetrics generations

## Status

Implementation in progress; the focused gates pass but independent review has unresolved findings (see the resume checkpoint below). Preserve the existing accepted M12 overlap Collector/isolation contract. This plan covers only offline/config/synthetic capability for backend and VictoriaMetrics integration; runtime, TLS, capture roots, CI activation, M13, Gate 5, and candidate promotion are excluded. Candidate remains DIAGNOSTIC ONLY and M19 remains NOT READY.

## Resume checkpoint — 2026-10-06

The working tree is intentionally dirty and must be preserved exactly. Do not reset, stash, clean, or discard changes. No commit or push was made. Existing unrelated dirty files—including `.gitlab-ci.yml` and the broad M19 implementation—were present; this task did not edit CI.

Current task changes are limited to:

- `scripts/lib/GeordiM12OverlapGenerations.ps1`: overlap-local backend/VM generation and evidence lifecycle, plus an exact identity/volume precondition check immediately before reset container removal.
- `scripts/Test-GeordiM12OverlapBackendVmGenerations.ps1`: synthetic entry, volume, VM evidence, backend handoff, combined sequence, and cross-service failure tests.
- `scripts/Test-GeordiM12OverlapCollector.ps1`: replaced the stale direct-call count with AST checks for the single adapter and its two ordered phase-specific callback bindings.
- `scripts/verify-alert-scheduling-overlap.ps1`: generation-aware opt-in wiring; standalone default remains the legacy path.
- this ExecPlan checkpoint.

Synthetic checks run before the ordered validation:

- Parser for the four changed PowerShell scripts: PASS.
- Compose normal render and isolated render, config-only: PASS, 13 services each; the rendered volume and propagation assertions were accepted.
- New overlap synthetic cases Commands, Entry, Volumes, Evidence, Backend, Sequence, and CrossFailure: PASS after fixing a test callback fixture. The final sequence checks G0→H1→G1→H2→G2, C0→HC1→C1→HC2→C2, V0→V1 and exact synthetic M13-entry state. CrossFailure confirms completed Collector history and V0 evidence remain unchanged when backend replacement fails, with incomplete backend handoff and no G2.
- No runtime/container lifecycle, TLS, capture-root, cleanup, CI, M13, or Gate 5 execution occurred. Config-only Compose rendering did invoke `docker compose config`; it did not start or mutate containers.

The prior stop at gate 5 was investigated. The assertion counted two direct calls to `Invoke-M12OverlapCollectorReplacement`, while production deliberately defines that adapter once and invokes it from separate reset/exercise callbacks. The test now verifies one adapter definition, both phase-specific callback invocations, their ordered binding to the accepted reset sequencer, the opt-in alias, and the standalone branch. No production Collector behavior changed for this correction.

The complete ordered 26-gate offline/config/synthetic validation was restarted and passed:

1–5. Parser, current lifecycle map, normal/isolated Compose renders, and accepted 7→0 Collector propagation/self-test: PASS.
6–12. Entry identity/follower authentication, volume inventory/inspect fail-closed behavior, protected-volume negatives, reset/recreate VM evidence ownership, VM source identity positive and in-acquisition change rejection: PASS.
13–16. First and second backend boundaries, backend failure checks, shared M12 backend regression, combined backend graph: PASS.
17–21. Accepted Collector self-test, combined backend/Collector/VM orchestration, cross-service partial failure, standalone default, synthetic M13-entry contract: PASS.
22–25. Accepted M12 backend-generation and Collector-replacement suites, shared manifest regression, M11 VM identity and persisted metric evidence regressions: PASS.
26. `git diff --check`: PASS; only existing CRLF/LF normalization warnings were emitted.

Fresh independent read-only review found **0 BLOCKER, 0 HIGH, 2 MEDIUM, 1 LOW, 0 INFO**. Do not auto-remediate these findings in this slice:

- MEDIUM: `Complete-GeordiM12OverlapBackendHandoff` invokes readiness inside the follower callback before the shared lifecycle validates the returned process record/container binding. Inspect and resolve this readiness-order concern before claiming the backend replacement contract is proven.
- MEDIUM: overlap-specific tests do not exercise the full backend failure matrix through both overlap handoff boundaries. Existing M12 tests invoke a different wrapper and do not close this coverage gap.
- LOW: the CI nonactivation assertion recognizes only the legacy mode alias and should also detect `-ApplyM12OverlapGenerations`.

The independent review reports the slice is NOT READY FOR OWNER ACCEPTANCE. Do not change code based on these review findings until the owner authorizes the next remediation slice. Owner-acceptance documentation remains unchanged. Next action: owner review of the two MEDIUM findings (and LOW note), then a separately scoped remediation and fresh validation/review if authorized.

No runtime/container lifecycle, TLS, capture-root, cleanup, CI, M13, Gate 5, or candidate-promotion operation occurred. Config-only Compose rendering invoked `docker compose config` only. Final status remains `M12 overlap backend/VM integration: REMEDIATION REQUIRED`, `M13: BLOCKED`, `Gate 5: BLOCKED`, `M19 NOT READY — REMEDIATION REQUIRED`.

## Goal

Extend the explicit M12 overlap generation-aware mode so it authenticates incoming M12 backend, Collector, and VictoriaMetrics state before mutation; records two backend handoffs and one persisted-metric VM identity boundary; isolates legacy aggregate captures from authoritative followers; and fails closed on uncertain volume ownership.

## Non-goals and invariants

- Do not modify `.gitlab-ci.yml`, M13, shared capture/Collector/backend helpers, schema, TLS, real capture evidence, protected volumes, or runtime state.
- Keep standalone overlap behavior as the default. Do not activate the new mode in CI.
- Preserve accepted Collector graph C0→HC1→C1→HC2→C2, readiness error precedence, service-scoped `--no-deps --force-recreate otel-collector`, and 7→0 restart isolation.
- Use two backend identity transitions if current orchestration confirms them; never collapse them.
- Treat VictoriaMetrics as a persisted-evidence source identity, not a log generation.
- Preserve historical M11/M12 metric ledgers and snapshots; bind overlap evidence to exact pre/post VM identities.
- Do not remove a volume unless inventory and inspection succeed and exact ownership is proven; never select either protected M19 volume.
- Record truthful incomplete handoffs/partial cross-service progress. Never roll back or rewrite sealed evidence.

## Investigation sequence

1. Re-map current overlap orchestration, service mutation order, mode/default behavior, and exact Compose file sets.
2. Trace incoming M12 backend/Collector generations and VM identity; determine the minimal preflight that runs before any destructive action.
3. Classify `m12-overlap-reset` and `m12-overlap-recreate` artifacts and whether generation followers or the persisted-evidence helper already own each interval/source.
4. Inspect overlap volume inventory/removal implementation and exact M12 logical labels, deletion allowlist, protected mounts, and failure seams.
5. Verify accepted M12 backend/Collector helper compatibility and persisted VM snapshot contracts. Stop if shared helper semantics or schema must change.
6. Freeze the intended synthetic orchestration order and failure-state behavior in tests before production-flow edits.

## Confirmed source findings

- The opt-in flow has exactly two backend identity changes: reset removal followed by backend start, then the later raw `up --force-recreate backend` boundary. The latter currently lacks `--no-deps`.
- The mode authenticates no incoming backend/Collector generation and checks no incoming exact VM identity before mutation. Its M12 volume loop treats a failed `volume inspect` as absence.
- The reset aggregate snapshot suppresses only Collector logs; backend remains an unbound aggregate owner. The recreate aggregate snapshot also publishes unbound backend logs.
- Both overlap VM phases use fixed snapshot/ledger paths and overwrite manifest captures. Existing `-SkipLogSnapshot` suppresses only logs.
- The accepted backend wrapper is phase-bound to main M12 evidence paths. The accepted generic handoff functions and persisted metric primitives support an overlap-local wrapper/publisher, so no shared generation or Collector helper change is needed.
- The existing M11 volume-inspection adapter distinguishes successful absence from inventory/inspect errors and can be reused without changes, paired with the exact M12 allowlist.
- Intended generation-aware reset order: authenticate backend/Collector/VM and all five volumes; publish immutable reset metrics bound to V0; seal backend G0; stop traffic fixture; remove backend/VM containers; perform accepted C0→C1; remove only owned M12 volumes; start isolated V1/query gate; perform accepted C1→C2; recreate backend under the pending G0 handoff and start exact follower before readiness; then start traffic fixture. Before the second backend boundary, publish immutable recreate metrics bound to V1, then seal/recreate/start exact follower/readiness to obtain G2.

## Implementation sequence, only after investigation is conclusive

1. Add a single coherent opt-in overlap generations mode; reject incompatible partial flags/state and retain standalone default behavior.
2. Add overlap-local fail-closed VM/volume evidence adapters, with exact ownership tests and protected-volume substitution negatives.
3. Integrate exact entry-state authentication before mutation.
4. Bind and publish reset VM evidence from the exact incoming VM; perform the scoped VM reset only after publication and ownership checks.
5. Use accepted backend generation lifecycle around both overlap backend identity boundaries and accepted Collector lifecycle around both Collector replacements.
6. Suppress only generation-aware legacy aggregate backend/Collector log captures that duplicate authoritative follower intervals; bind persisted VM evidence to its source identity and immutable phase.
7. Enforce the final synthetic M13-entry state without implementing M13.
8. Run the ordered focused offline validation; stop at first failure. Obtain an independent read-only review only after all focused checks pass.

## Required proof

- Normal/isolated Compose config and 7→0 restart propagation.
- Incoming backend/Collector/VM and volume ownership preflight; failure occurs before mutation.
- Fail-closed volume inventory/inspect/removal matrix.
- Exact reset/recreate evidence ownership classification.
- Two sequential backend handoffs; one pre/post VM source-identity transition; accepted two-handoff Collector chain.
- Combined backend/Collector/VM order and failures after Collector success and after backend handoff one.
- Standalone default unchanged; all generation-aware source channels and final M13-entry predicates.
- Accepted M12 backend, Collector, manifest, and persisted-evidence regressions; parser; `git diff --check`.
- Fresh review: BLOCKER 0, HIGH 0, MEDIUM 0. Do not auto-remediate review findings in this slice unless explicitly authorized by the task's review rules; stop for owner if required.

## Stop conditions

Stop before destructive-call integration if incoming state cannot be authenticated before the first mutation, persisted evidence cannot be immutably bound to VM identity, volume ownership cannot fail closed without shared-helper changes, a legacy duplicate cannot be safely classified, or the accepted backend/Collector lifecycle cannot represent the required transition. Do not activate CI, implement M13, run Gate 5, or execute runtime operations.
