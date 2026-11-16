# ExecPlan: M11→M12 fixture transfer capability

## Status

Capability implemented, focused offline validation complete, and OWNER ACCEPTED. M19 remains `NOT READY — REMEDIATION REQUIRED`; candidate `6fe4e83ffaf7418ebcc7015a4c176b61` remains diagnostic-only. Gate 5 remains blocked. CI activation and runtime execution are out of scope.

## Goal

Add explicit M11 producer `PreserveFixtureForNextStage` and M12 consumer `ConsumeTransferredM11Fixture` modes. Both sides independently validate the existing persisted manifest, active backend generation/follower, immutable `m11-final` VictoriaMetrics ledger, live Compose identities, M11-owned volumes, and shared Collector continuity. The M12 mode performs only the `m12-reset` persisted metric capture with `-SkipLogSnapshot`, verifies its exact inherited VM source, then exits before destructive M12 fixture work.

No transfer file/ID/schema, runtime epoch, cross-script pending handoff, CI activation, or M12 backend replacement is introduced.

## Safety and compatibility

- M11 default remains standalone: successful runs clean up; failures clean up after bounded ownership checks.
- Preserve mode suppresses cleanup only after every transfer precondition validates and an internal success-commit flag is set. Any earlier failure follows current cleanup.
- M12 default and `-RunFixtureResetOnly` remain unchanged. Consume mode is a separate explicit top-level branch before normal reset logic.
- Reuse existing capture-generation and persisted-metric validators; do not mark or seal active G3 for transfer.
- Use synthetic identities/adapters and config-only Compose rendering. Never run Docker lifecycle operations or touch live captures/volumes.
- Do not change `.gitlab-ci.yml`.

## Implementation and proof

Create a shared read-only validator for the persisted transfer contract with injected live identity, follower process, volume, and capture adapters. Producer captures the starting Collector identity, validates final backend/VM/Collector state and exact M11 volumes after `m11-final`, then commits preservation. Consumer reloads the manifest from disk in a fresh invocation, repeats all checks, captures `m12-reset` against inherited VM, verifies a current-run VictoriaMetrics export bound to that same VM, and stops.

Tests serialize/reload producer state and cover the required A–S consumer matrix, producer failure cleanup, success-only preservation, exact resource ownership, standalone defaults, log-snapshot suppression, branch ordering, and no destructive action on failed transfer. Run the requested 18 focused gates fail-fast, then independent read-only review. Shared helpers are unchanged unless concrete incompatibility requires a change; if changed, rerun accepted M10/M11/M12 compatibility checks.

## Stop condition

Owner acceptance records the transfer capability only. Gate 5 remains blocked; CI remains unmodified; M12 backend generation and the atomic future activation slice remain pending.

## Validation record — 2026-10-04

- Affected PowerShell parser: PASS (transfer helper, transfer self-test, M11 producer, M12 consumer).
- Transfer self-test: PASS. Covers default standalone modes, M11 preserve success and six producer-failure preconditions, fresh-process consumer authentication, M12 reset interval binding, incompatible-mode rejection, and consumer rejection matrix A–S.
- M11 final evidence self-test: PASS.
- Shared capture-generation manifest regression: PASS.
- `git diff --check`: PASS; Git printed only existing CRLF/LF conversion warnings.
- Independent read-only review: BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0 / INFO 0.

The review confirmed the transfer remains schema-free and CI-unactivated. It does not prove live M11/M12 behavior or the future destructive M12 backend handoff. Shared generation/evidence helpers were not changed. M11 backend generation remains owner-accepted; M12 backend generation remains unimplemented; Gate 5 remains blocked.

## Owner acceptance — 2026-10-04

The owner accepted the M11 backend generation slice and the M11→M12 fixture-transfer capability. CI transfer activation remains NOT ACTIVATED; M12 backend generation remains NOT IMPLEMENTED. Gate 5 remains BLOCKED, Gates 6–17 remain NOT RUN, the candidate remains DIAGNOSTIC ONLY, and M19 remains NOT READY — REMEDIATION REQUIRED.

## Atomic activation test remediation — 2026-10-04

Superseding the earlier pending-activation status above: the authoritative CI
activation is implemented and ready for owner acceptance. Only test files changed
during this remediation. The CI contract parser retains `CommandParameterAst`
metadata and requires unique bare M11/M12 activation switches; attached values,
duplicates, mixed forms, comments, and non-command occurrences fail closed. The
M12 AST proof requires a direct positive consumer switch, exact negation of the
Apply switch, and an exact literal integral `exit 0`. The negative fractional
fixture matches PowerShell's actual signed-number AST and confirms that the frozen
validator rejects it. Metric fingerprints are captured immediately after accepted
publication/reuse and checked across later generation boundaries, with intermediate
content and manifest-reference negative controls.

The full remediation micro-suite passed, then formal offline gates 1–19 passed
from Gate 1. A fresh independent read-only review found BLOCKER 0 / HIGH 0 / MEDIUM
0 / LOW 0 / INFO 0. No runtime proof was run and no production, CI wiring, or shared
helper change was made during this remediation. M11 backend generations,
M11→M12 transfer capability, and M12 backend generations remain OWNER ACCEPTED;
Gate 5 remains BLOCKED, the candidate remains DIAGNOSTIC ONLY, and M19 remains
NOT READY — REMEDIATION REQUIRED. Next action: owner review; this offline proof does
not authorize or claim runtime acceptance.
