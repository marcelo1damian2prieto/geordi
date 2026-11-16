# ExecPlan: M12 backend generation integration

## Status

Implementation and focused offline validation complete; OWNER REVIEW PENDING. M11 backend generations, M11→M12 transfer capability, and M12 Collector replacement are OWNER ACCEPTED. This slice integrates backend capture generations into an explicit M12 transferred-fixture execution path only. It does not activate the path in CI. Candidate `6fe4e83ffaf7418ebcc7015a4c176b61` remains DIAGNOSTIC ONLY; Gate 5 remains BLOCKED and M19 remains NOT READY.

## Goal

After the M12 consumer independently validates transferred M11 state and publishes the inherited-VM `m12-reset` evidence, perform the real M11→M12 backend boundary through the shared capture handoff lifecycle. Continue the explicit M12 smoke path with each subsequent M12 backend replacement represented by a distinct container generation. Preserve M12 scheduler, outage, and persistence assertions. Keep the standalone M12 path and `.gitlab-ci.yml` unchanged.

The transferred `m12-reset` ledger is authoritative evidence for the inherited M11 VictoriaMetrics generation. Do not overwrite it with later M12 fixture evidence; use a distinct phase identity for the post-reset scheduler boundary if required.

## Safety and compatibility

- No Docker runtime operations, live M11/M12, TLS/certificate changes, capture-root edits, cleanup, or protected-volume operations during implementation and validation.
- No `.gitlab-ci.yml` activation, commit, push, or new candidate.
- Do not change M11, accepted M10/M11 helpers, or accepted M12 Collector semantics unless a concrete incompatibility is proven.
- In transferred mode, only the exact inherited M11 backend/VM containers and exact M11 volumes may be removed. M12 backend/VM volumes are separately checked against exact M12 ownership labels before any reset.
- Every backend replacement seals the old active generation and follower, uses a bounded service-scoped Compose action, requires a new backend container ID, starts an exact follower, waits for readiness, and publishes/completes the shared handoff. Failure remains incomplete and fail-closed.
- Outside explicit transferred mode, existing M12 standalone behavior remains unchanged.

## Implementation sequence

1. Inspect M12 reset and backend-restart behavior, Compose overlays, and existing generation helpers.
2. Add the smallest M12 backend handoff helper around `Begin-GeordiCaptureHandoff` and `Invoke-GeordiCaptureHandoffReplacement` with injected identity, replacement, follower, and readiness adapters.
3. Integrate transferred-fixture reset after `m12-reset`; preserve that evidence and isolate the M11→M12 service/volume replacement from M12 Collector replacement and M12 fixture initialization.
4. Integrate subsequent M12 backend container replacements in the explicit transferred run, including scheduler enablement and provider-recovery restart, while preserving persistent M12 alert data and existing behavior assertions.
5. Ensure each persisted metric phase has a distinct immutable identity and exact live VictoriaMetrics source binding.
6. Add synthetic positive-chain, command-scope, error-state, and negative boundary tests. No real Docker.

## Implemented behavior

- `-ApplyM12BackendGeneration` requires `-ConsumeTransferredM11Fixture`; consumer-only mode still validates transfer, records `m12-reset`, and exits before any destructive M12 boundary.
- The applied transfer validates the inherited M11 identities and immutable `m12-reset` ledger before beginning the shared backend handoff. The callback removes only the exact M11 backend/VM containers, removes exact labeled M12 fixture volumes, performs the accepted controlled Collector replacement, starts M12 VictoriaMetrics and burn-demo with dependencies disabled, then starts the M12 backend. Exact M11 volumes are retained until the new M12 backend generation is ready, then removed with presence and ownership revalidation.
- The initial M11→M12 boundary, scheduler enablement, and provider-recovery backend replacement use `Invoke-GeordiM12BackendGenerationReplacement`. Each requires a distinct backend container ID, exact follower binding, readiness, and a completed shared handoff. Scheduler and recovery Compose recreation requests target only `backend` with `--no-deps --force-recreate`.
- The transferred path records separate immutable VictoriaMetrics evidence phases: inherited `m12-reset`, fresh M12 `m12-fixture-start`, and pre-outage `m12-recovery-start`. The existing standalone M12 flow retains its prior reset and restart behavior.
- No `.gitlab-ci.yml` activation or runtime operation was made. The diagnostic candidate remains diagnostic-only.

## Focused validation completed

- PowerShell parser: PASS for the directly affected scripts and helpers.
- `Test-GeordiM12BackendGenerations.ps1 -Case SelfTest`: PASS, including a four-generation/three-handoff synthetic chain, fail-closed boundary cases, immutable stream checks, exact M12 volume ownership, command-scope checks, metric-phase identity/immutability, and transfer-path wiring.
- `Test-GeordiM11M12FixtureTransfer.ps1 -Case SelfTest`: PASS.
- `Test-GeordiM12CollectorReplacement.ps1 -SelfTest`: PASS; config-only Compose render verified unchanged Collector semantics and disabled dependency restart propagation.
- M11 backend-generation, final-evidence, VM-identity, persisted-metric-export, and ledger-interval self-tests: PASS.
- No real Docker lifecycle, M11/M12 smoke, Gate 5 ordered run, CI activation, or M19 acceptance was performed.

## Validation and stop conditions

Run the affected PowerShell parser, M12 backend-generation self-test, transferred fixture self-test, M12 Collector compatibility self-test, persisted metric identity/manifest regressions needed by phase naming, and `git diff --check`, stopping on the first failure. Obtain a fresh independent read-only review; resolve BLOCKER/HIGH findings and report MEDIUM/LOW findings. Update milestone documentation only after clean review.

Do not claim Gate 5 complete. CI transfer activation is a later separately reviewed slice. After this slice, the next action is owner review of M12 backend generation integration; the later atomic M11→M12 CI activation remains pending.
