# ExecPlan: M11 backend capture generations

## Status

Focused implementation and offline validation complete; awaiting owner review before any next gate. M19 remains `NOT READY — REMEDIATION REQUIRED`; candidate `6fe4e83ffaf7418ebcc7015a4c176b61` remains diagnostic-only. No runtime gate is authorized by this plan.

## Outcome

Wrap the three authoritative M11 backend container boundaries with the existing capture-generation handoff lifecycle:

1. Initial joint backend/VictoriaMetrics fixture reset.
2. Backend downtime while the notification receiver recovers.
3. Backend replacement for the application-restart/no-redelivery assertion.

Each backend transition must seal the exact old follower, run the existing stage action, resolve a distinct owned backend container, start an exact-ID follower, wait for readiness while that follower is active, and complete a validated handoff. The initial VM reset must retain the M11-only propagation-isolation Compose overlay, bind `m11-reset` to VM_OLD, recreate only backend and VictoriaMetrics, and prove VM_NEW differs from VM_OLD. M11's persisted metric evidence remains a snapshot/ledger, not a VM log generation.

## Boundaries

- Reuse `Begin-GeordiCaptureHandoff`, `Invoke-GeordiCaptureHandoffReplacement`, and `Start-GeordiCaptureGeneration`; do not duplicate manifest lifecycle logic.
- Keep the normal M11 Compose context unchanged. Add the accepted isolation overlay only to explicit controlled replacement argv.
- Preserve existing delivery IDs, receiver controls, readiness checks, M11 datasource and dedicated volumes, and no-duplicate assertions.
- Retain default standalone M11 cleanup. Seal an active M11 backend generation before final removal so captured evidence is complete.
- Do not implement M11→M12 fixture transfer or preserve mode in this slice.
- Do not run M11/M12/M14 runtime, Finalize, cleanup, Docker mutations, TLS operations, CI, or candidate creation. Do not touch captures or protected volumes.

## Proof

Use synthetic container identities and mocked Compose, readiness, follower, and volume adapters. Cover the positive three-boundary sequence, exact follower/container identity, distinct container IDs, immutable old captures, overlay command scope, volume preservation, readiness-before-completion, and fail-closed behavior for missing/mismatched old generation, old seal failure, Compose failure, missing/same new ID, readiness failure, follower startup failure, and handoff publication failure. Prove M11's semantic assertions remain in place and M12/other Compose paths do not inherit the overlay.

Run only affected PowerShell parsers, focused M11 generation helper and boundary tests, the already accepted M11 propagation-isolation self-test updated for production command wiring, and `git diff --check`. Obtain an independent read-only review before updating milestone status. Gate 5 remains blocked until the later M11→M12 transfer slice and complete ordered proof.

## Completed offline proof — 2026-10-04

- M11 synthetic three-boundary generation chain: PASS; exact follower/container identity, distinct IDs, readiness ordering, and sealed-history immutability verified.
- M11 dedicated-volume cleanup helper: PASS with mocked adapters; exact two-volume allowlist, successful-inventory absence, failed-inventory fail-closed, foreign ownership rejection, and protected M19 volume rejection verified.
- M11 Compose propagation isolation: PASS; normal render has two restart-propagating dependents, isolated render has zero, and only the intended dependency settings differ. Ambient `COMPOSE_FILE` source-contract checks pass when absent and nonempty.
- M11 final evidence and VictoriaMetrics identity tests: PASS.
- M10 replacement cases (config, propagation, protected-volume, positive handoff, fail-closed, duplicate capture, static semantics): PASS.
- M12 Collector replacement self-test: PASS.
- PowerShell parser: PASS for 10 affected scripts. `git diff --check`: PASS; Git emitted only existing-worktree CRLF/LF normalization warnings.
- Fresh independent read-only review: BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0.

No runtime, Docker lifecycle, TLS, captures, or protected volumes were modified. M11→M12 fixture transfer remains out of scope and unimplemented. Gate 5 remains blocked; Gates 6–17 were not run. This is offline focused readiness for owner review, not M19 acceptance.
