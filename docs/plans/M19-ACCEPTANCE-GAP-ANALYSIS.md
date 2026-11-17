# M19 — Acceptance Gap Analysis

**Date:** 2026-11-16 (America/Buenos_Aires)  
**Branch:** `d2/audit-boundaries-fix`  
**Base:** `m19` at `6afb4177135824165c45e2db07f86ebc6d5b00de`  
**Purpose:** reconcile the original M19 acceptance requirements with the latest available repository evidence.  
**Status:** analysis only; M19 remains **NOT READY — REMEDIATION REQUIRED**.

## 1. Scope and method

This document is a read-only evidence reconciliation. It does not change M19 implementation, CI, Compose, runtime state, TLS material, captures, candidate state, or protected volumes. It does not authorize tests, Docker commands, cleanup, CI activation, M13, Gate 5, candidate promotion, or M19 acceptance.

The primary acceptance source is [MILESTONE-019.md](MILESTONE-019.md), especially:

- § Complete HTTP operation policy and the preceding identity, permission, JWT, OIDC, session, CSRF, failure and observability contracts.
- § Concrete test matrix (25 categories).
- § Semantic smoke, fixture reuse and CI budget.
- § Implementation completion criteria.

The current evidence sources are:

- [M19-D2-TEST-INFRASTRUCTURE-AUDIT.md](M19-D2-TEST-INFRASTRUCTURE-AUDIT.md)
- [M19-ACCEPTED-REGRESSION-RECONSTRUCTION.md](M19-ACCEPTED-REGRESSION-RECONSTRUCTION.md), particularly § 11 and the 2026-11-16 P0–P8 execution closure.
- [M19-WORKTREE-RESUME-CHECKPOINT.md](M19-WORKTREE-RESUME-CHECKPOINT.md)
- [EXECPLAN-M19-FINALIZE-RESUMABILITY.md](EXECPLAN-M19-FINALIZE-RESUMABILITY.md)
- The scoped M10, M11, M11→M12 transfer, M12 backend, M12 overlap backend/VM and M12 overlap Collector ExecPlans.

Status vocabulary:

- **VERIFIED (focused):** the cited, bounded check has explicit PASS evidence. This does not imply milestone acceptance.
- **PARTIAL:** relevant evidence exists, but it is historical, scoped, incomplete, not bound to the latest complete candidate, or lacks a required companion proof.
- **MISSING:** no qualifying evidence was found in the inspected sources.
- **BLOCKED:** the criterion cannot be accepted until a named dependency or separately authorized operation is resolved.
- **NOT RUN:** the source explicitly records that the operation was not performed.

A PASS from a focused test, synthetic harness, config render, or delta review is never promoted to a full runtime or milestone PASS.

## 2. Executive result

The D2 branch has a **GREEN reconstructed P0–P8 focused execution** recorded in the reconstruction and resume-checkpoint documents. That sequence validates the D2 test-infrastructure and post-follower-readiness scope. P8 is a read-only static review; it is not a fresh independent human sign-off for the whole M19 milestone.

That result does not close the M19 acceptance criteria. The latest diagnostic candidate record is still blocked: the 2026-09-30 fresh candidate passed through M13 and stopped at the M14 route-A assertion (`M14 route A did not create ALERT_STARTED`). M15–M18 and Finalize did not run for that candidate. The same record says the credential scan, artifact scan, manifest publication and complete Finalize timing were NOT RUN. The Finalize ExecPlan continues to classify the candidate as diagnostic-only.

The milestone therefore remains **M19 NOT READY — REMEDIATION REQUIRED**.

## 3. Acceptance evidence matrix

| ID | Original acceptance area | Evidence found | Status | Gap / qualification |
|---|---|---|---|---|
| M19-A01 | Backend quality: full Java 21 Maven verify, tests, PMD, SpotBugs, Find Security Bugs and ArchUnit | The milestone records successful backend runs, including 542 tests on the 2026-09-30 diagnostic candidate, with static-analysis gates passing. | PARTIAL | The run is candidate-specific historical evidence, not a fresh complete validation tied to an accepted immutable candidate and full closure record. |
| M19-A02 | Frontend quality: install, tests, typecheck, lint and production build | The milestone records 235 frontend tests plus typecheck, lint and build passing on the 2026-09-30 diagnostic candidate. | PARTIAL | Same candidate/provenance limitation as A01; the result does not close browser/runtime or milestone gates. |
| M19-A03 | Security contract matrix: canonical identity and grants, application guards, wiring, JWT/JWKS, credential ambiguity, OIDC, sessions, CSRF, proxy/origin, routes, actuator, /me, ACK, V8, replay, concurrency, scheduler, frontend and security telemetry | The 25-category test matrix is explicit in MILESTONE-019. Multiple focused backend, frontend, browser and security-smoke results are recorded. | PARTIAL | The source does not provide a single current-candidate, row-by-row evidence ledger for all 25 categories. The detailed live actuator/startup contract matrix is explicitly still incomplete in the D2 audit. |
| M19-A04 | OpenAPI 3.1 validation and correspondence with routes, schemas, security requirements and errors | OpenAPI lint/bundle validation is recorded as passing in a prior candidate checkpoint. | PARTIAL | No final-candidate reconciliation record maps every operation/schema/security declaration to the final implementation and test evidence. |
| M19-A05 | Supported Compose overlays, Collector/Tempo/Loki configuration and fail-closed startup validation | MILESTONE records Compose/configuration checks on selected M19/M12/M13 paths. D2 P6 separately passed normal and isolated M12 overlap Compose config rendering, including seven-to-zero restart propagation and protected-mount equivalence. | PARTIAL | D2 P6 is config-render-only and narrowly scoped. The available record does not establish a fresh complete validation of every supported overlay plus the full deployment/startup contract matrix. |
| M19-A06 | M19 security smoke: probes, authenticated read/mutation permissions, ACK attribution/replay, lifecycle permission and scheduler behavior, invalid tokens and ambiguous credentials | The milestone records successful focused security smoke runs, including a 2026-09-29 run, and real Chromium OIDC/session/CSRF/logout E2E. | PARTIAL | Focused smoke evidence exists, but it is not the same as the complete final candidate sequence and does not resolve the M14 stop, final evidence, cleanup or full independent review. |
| M19-A07 | Complete authenticated M9–M18 ordered semantic regression chain | A 2026-09-24 local CI-equivalent checkpoint reports a complete serial chain. The later 2026-09-30 fresh diagnostic candidate passed M9–M13 and stopped at M14. | BLOCKED | For the latest diagnostic candidate, M14 failed and M15–M18 did not run. Earlier success is historical and cannot replace a successful chain on the final candidate. Diagnose M14 route A, then obtain authorization for a fresh fail-fast candidate run. |
| M19-A08 | Positive-controlled nine-channel runtime credential-leak scan, including persisted sources | Earlier milestone checkpoints contain positive-control scan evidence, but the later diagnostic candidate did not reach Finalize. D2-06 still identifies the nine-channel scan as unverified for closure. | PARTIAL / NOT ACCEPTED | There is no qualifying final-candidate Finalize and nine-channel evidence bundle. Do not treat scanner self-tests or exploratory captures as runtime proof. Reconcile the earlier positive-control checkpoint against the exact candidate/run identity before claiming it as reusable evidence. |
| M19-A09 | Sanitized failure-diagnostic scan/publication | Earlier diagnostic and scanner work exists; the D2 audit lists the sanitized failure-diagnostic scan as unverified. The 2026-09-30 candidate stopped before Finalize. | MISSING for final candidate | No final-candidate failure-path capture/scan/publication result is recorded. |
| M19-A10 | Complete publishable-artifact inventory and credential scan | Prior structural inventories and partial artifact scans are recorded. D2-06 identifies the publishable-artifact sweep as incomplete; the 2026-09-30 candidate did not run the final artifact scan. | PARTIAL | Repeat the complete inventory and sentinel scan against the final candidate's publishable outputs after all build/report changes. Preserve hashes and archive-entry coverage. |
| M19-A11 | Source/JAR/image provenance | Several historical Maven/staging/runtime JAR hashes and image labels matched. The 2026-09-30 candidate has recorded local artifact digests. | PARTIAL | The recorded OCI revision points to a committed base while the candidate was diagnostic/dirty; no accepted immutable source-to-candidate provenance and final promotion record exists. |
| M19-A12 | Full CI critical-path timing against 27-minute script and 30-minute job budgets | A historical local serial run reported 1,258.02 seconds. Other checkpoints explicitly state that no valid complete timing was established for the current candidate. D2-04 identifies the end-to-end critical path and timeout budget as unproven. | BLOCKED | No qualifying current-candidate end-to-end timing ledger on the target Windows runner and no GitLab pipeline execution. Historical individual durations or a local run from another candidate are not a substitute. |
| M19-A13 | Successful strict cleanup, with runtime/TLS/evidence removal verified and both protected M19 volumes preserved | A prior strict cleanup retry passed, but an older temporary directory remained. The 2026-09-30 candidate stopped with 11 containers and a network present; cleanup was not run. D2-05 identifies runner isolation as mandatory because cleanup is destructive to project-scoped resources. | BLOCKED | Current candidate cleanup is not proven. It requires a dedicated/isolated runner or Docker daemon and a separately authorized cleanup operation. Preserve both protected M19 volumes. |
| M19-A14 | Finalize: complete live capture, Tempo, Loki, VictoriaMetrics, credential scan, artifact scan and atomic accepted manifest | The Finalize ExecPlan records earlier diagnostic attempts stopping in Tempo/Loki. The latest 2026-09-30 candidate stopped at M14 before Finalize; its Finalize phases and completion marker are NOT RUN. | BLOCKED | No completed Finalize attempt or accepted/completed manifest exists for the latest candidate. Do not retry until M14 and the required preconditions are resolved and a new narrow authorization is granted. |
| M19-A15 | Fresh independent final implementation/milestone review, with findings resolved and affected gates rerun | Multiple focused delta reviews and the D2 P8 read-only static review exist. | MISSING for milestone closure | No fresh independent review of the complete final candidate, all M19 evidence, cleanup, CI timing and final diff is recorded. D2 P8 is not a substitute. |
| M19-A16 | Reproducible operational documentation, synchronized architecture/API/history docs and ADR-022 | MILESTONE-019 lists documentation reconciliation and ADR-022 as completion work. The inspected `docs/adr` directory contains ADR-001 through ADR-021; ADR-022 is absent. | PARTIAL | Existing docs are present, but ADR-022 and a final cross-document reconciliation are not evidenced. |
| M19-A17 | Rollout/rollback readiness and final M19 acceptance decision | The plan defines a coordinated single-node rollout, backup, issuer/audience/TLS/secret validation, additive V8, authenticated checks and ingress cutover. | BLOCKED | This is a release/acceptance activity, not part of D2. No final acceptance or rollout authorization exists. |

## 4. D2 result versus M19 acceptance

The 2026-11-16 D2 P0–P8 result is bounded to:

- branch/worktree preconditions and scope;
- PowerShell parser inventory;
- five shared post-follower seam tests;
- M11, M12 backend and M12 overlap-backend synthetic caller tests;
- capture-generation AuthContract and Boundaries;
- M12 overlap Collector synthetic SelfTest;
- separately authorized M12 overlap Collector Compose config-render integration;
- read-only diff/scope review and a read-only static review.

It does **not** include the complete M9–M18 semantic chain, M14–M18 runtime, Finalize, a final-candidate nine-channel scan, final artifact scan, CI pipeline execution, CI timing proof, strict cleanup, TLS/certificate work, or M19 acceptance.

The D2 audit's D2-11 section still says the reconstructed P0–P8 sequence is NOT RUN. That statement is superseded by the later 2026-11-16 execution-closure addenda in the reconstruction and worktree-resume documents. Preserve the older D2-11 text as history; if desired, reconcile it with a dated append-only correction rather than rewriting it.

## 5. Separate workstreams — do not merge into P0–P8

The following are independent validation units and must retain their own scope, approvals and acceptance records:

1. M10 seven-case replacement suite.
2. M11 backend-generation owner acceptance.
3. M11→M12 fixture-transfer 18 focused gates / A–S matrix.
4. M11→M12 remediation and atomic activation 19-gate sequence.
5. M12 backend-generation integration owner review/acceptance.
6. Formal M12 overlap backend/VM 26-gate sequence and its independent review findings.
7. M12 overlap Collector lifecycle/isolation plan and its independent review.
8. M13 implementation/entry validation and Gate 5.
9. M14–M18 semantic runtime chain.
10. Finalize, runtime evidence, cleanup and full M19 acceptance.

Some of these have focused PASS records; others have owner acceptance for a capability only. None should be silently treated as a single completed M19 gate because the focused checks have different purposes, safety boundaries and dependencies.

## 6. Dependency and blocker register

| ID | Dependency / blocker | Why it matters | Resolution evidence required | Safety boundary |
|---|---|---|---|---|
| GAP-01 | M14 route-A failure | Latest diagnostic candidate stopped at `M14_initial_condition_and_episode`; M15–M18 and Finalize did not run. | Source-level diagnosis with a concrete failing predicate; then a fresh authorized candidate run that passes M14 and the remaining ordered chain. | Diagnose read-only first. Any runtime rerun requires separate explicit approval. |
| GAP-02 | Finalize not completed on latest candidate | No final runtime/persisted-source scans, artifact scan, manifest completion or total Finalize timing. | Complete attempt-scoped Finalize evidence, all required channels/sources, scanner results and atomic completion marker. | New candidate/Finalize operation requires narrow authorization; never reuse or overwrite prior attempts. |
| GAP-03 | Nine-channel and sanitized failure diagnostics not accepted | D2 audit lists both as unverified for closure; older positive-control checkpoints are not bound in the current record to a completed final candidate. | Candidate/run-bound manifest, channel-specific positive controls, clean sentinel scan, persisted Loki/VictoriaMetrics evidence and sanitized failure-diagnostic scan. | Private evidence only; no raw secrets in logs, manifests or published artifacts. |
| GAP-04 | Artifact sweep and provenance not final | Earlier inventories/hashes exist but are not the final complete candidate sweep. | Complete publishable-path/archive inventory, sentinel scan, immutable source/JAR/image digest correlation and recorded candidate identity. | Do not expose or promote diagnostic artifacts. |
| GAP-05 | CI invocation and timing gaps | The D2 audit notes Boundaries/AuthContract are not directly invoked by the visible GitLab pipeline; full critical path and timeout margin remain unproven. | Reviewed CI gate plan, explicit decision on invocation coverage, repeated target-runner timing ledger and authorized pipeline result. | No CI edit or activation without a separate approved change. |
| GAP-06 | Cleanup environment not proven isolated | Cleanup removes project containers/network and temporary TLS/capture material. | Dedicated runner/daemon identity, pre/post resource inventory, cleanup result and exact protected-volume preservation proof. | Never run cleanup against the developer's shared Geordi daemon; never remove protected M19 volumes. |
| GAP-07 | Full independent milestone review absent | Focused reviews do not cover the complete candidate and all closure evidence. | Fresh independent review of exact final commit/candidate, all evidence and current diff; disposition all severities; rerun affected gates. | Review must be read-only; no implicit remediation authority. |
| GAP-08 | Documentation status drift | D2-11 says P0–P8 NOT RUN while later reconstruction/checkpoint addenda record P0–P8 GREEN. ADR-022 is absent. | Append-only status reconciliation and final documentation/ADR-022 completion. | Preserve historical statements; add dated corrections rather than rewriting history. |

## 7. Recommended order of work

This is a recommendation, not authorization to execute the protected steps.

1. **Read-only source diagnosis of M14 route A.** Identify the exact assertion, fixture state, route/event ordering and likely cause from the relevant script and implementation. Do not start runtime or alter the candidate.
2. **Owner review of the M14 diagnosis and a bounded remediation proposal.** Freeze the intended change and acceptance checks before implementation.
3. **Separate authorization for a fresh candidate and ordered runtime chain.** Start from the required preconditions, preserve prior diagnostic evidence, stop at the first failure, and record the exact candidate/source/artifact identity.
4. **Only after M14–M18 pass, authorize Finalize separately.** Capture all required channels and persisted sources; require positive controls, sanitized failure evidence, complete artifact inventory and atomic manifest completion.
5. **Prove provenance and timing.** Bind source commit, JARs, image labels and runtime image; measure the complete serial critical path against the configured 27m/30m budgets on the target runner.
6. **Authorize strict cleanup only on an isolated runner/daemon.** Verify all in-scope containers/network/TLS/private evidence are removed and both protected M19 volumes remain.
7. **Obtain the fresh independent full-milestone review.** Resolve findings and rerun affected gates.
8. **Reconcile ADR-022 and operational documentation, then make a separate M19 acceptance decision.** Do not promote the diagnostic candidate.

## 8. Explicit non-authorization

This analysis does not authorize:

- Docker `up`, `down`, `restart`, `rm`, `prune`, build or volume mutation;
- runtime smoke, M14–M18 execution, Finalize or candidate creation;
- TLS/certificate bootstrap or cleanup;
- capture mutation, evidence-root cleanup or protected-volume access;
- GitLab pipeline execution, CI wiring/activation or timeout changes;
- M13 implementation, Gate 5, candidate promotion or M19 acceptance.

The D2 reconstructed P0–P8 result remains GREEN for its focused scope only. Overall milestone status remains **M19 NOT READY — REMEDIATION REQUIRED**.
