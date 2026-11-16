# ExecPlan: M10 backend capture-generation boundary

## Objective

Integrate the authoritative M10 backend container replacement with the shared M19 capture-generation handoff, preserving M10's dedicated persistence reset and keeping legacy M10 metric evidence.

## Current evidence

- M10 composes `compose.yaml`, `compose.m19.yaml`, and `compose.m10.yaml`.
- The normal M10 setup snapshots evidence, removes `backend`, deletes only the label-verified `geordi_m10-alert-lifecycle-data` volume, then runs `up -d --force-recreate backend`.
- M19 capture startup creates an exact active backend follower before the ordered milestone scripts.
- Effective Compose rendering has no backend dependent with `restart: true`; the frontend edge is `restart: false`.
- M10's datasource selects the dedicated M10 volume. The M19 alert volume is mounted, but is not the active M10 datasource; the VictoriaMetrics volume is not mounted by backend.
- The M10 reset snapshot currently adds an unbound backend log snapshot even though the active generation follower owns the same interval.

## Implementation scope

1. Add a small M10 orchestration helper that validates the exact active backend generation, seals it through the shared handoff functions, invokes the existing remove / dedicated-volume-reset / force-recreate order, resolves a distinct backend identity, and starts the new exact follower.
2. Keep the M10 persisted-metric snapshot while suppressing only the duplicate legacy M10 backend log snapshot.
3. Add synthetic positive, fail-closed, duplicate-ownership, config/propagation/volume, and M10 static-semantics regressions.
4. Preserve the later same-container backend restart and all M10 functional assertions.

## Validation and stop conditions

Run only the task-authorized parser, config-only Compose, propagation, protected-volume, synthetic M10 lifecycle, shared replacement/manifest, and diff checks. Stop on the first failure. Do not execute runtime Docker operations or continue to the complete Gate 5 chain. A fresh read-only review is required before returning for owner acceptance.

## Out of scope

M11, M12 backend, M13, M14, Finalize, runtime execution, TLS, existing captures, protected-volume mutation, CI, candidate creation, commit, push, and M20.
