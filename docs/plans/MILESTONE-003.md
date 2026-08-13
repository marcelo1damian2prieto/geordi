# Milestone 003 — Traces Vertical Slice

Status: READY FOR GITLAB REVALIDATION

## Objective

Deliver the smallest useful distributed-trace capability:

```text
Demo workload -> OTLP -> Collector -> Tempo
                                      ^
                                      |
React Traces <- REST <- Traces application <- query port <- adapter
```

The slice proves real trace ingestion, persistence, service-scoped discovery, bounded
search and detail inspection while preserving storage replaceability. It also adds the
first Metrics → Traces navigation by canonical context propagation.

## Product scope

An operator can select one monitored service and an absolute time range, inspect up to
50 matching trace summaries, open a complete trace detail and identify hierarchy,
duration and error status. From Metrics, the operator can open Traces carrying the
same service namespace/name, environment and exact time range.

The investigation identity is `service.namespace`, `service.name` and
`deployment.environment.name`, with `geordi.telemetry.origin=monitored`. Namespace is
an exact dimension: its omission means a canonical null/absent namespace, never a
wildcard. Search uses a valid half-open `[from, to)` interval no wider than six hours.
`errorOnly` is an optional filter. Durations and waterfall offsets are whole integer
nanoseconds.

## Non-goals

No Logs module, trace/log correlation, full APM, arbitrary TraceQL/query UI, saved
searches, service/dependency maps, flame graphs, profiling, alerts/SLOs, RUM,
synthetics, Kubernetes, tenancy/RBAC, multiple trace stores, or vendor migration work
is in this milestone.

## Decisions

- Tempo monolithic with local filesystem storage is the single trace provider
  (ADR-010).
- A small vendor-neutral trace query boundary is the only application/storage contract
  (ADR-011).
- Tempo versus Jaeger: both meet OTLP and trace lookup requirements; Tempo is selected
  for the smallest local monolithic filesystem deployment and HTTP adapter path.
  Jaeger's operational/storage alternatives and UI do not justify an additional
  product dependency for this slice.
- Metrics → Traces uses canonical identity plus absolute time context, not exemplars,
  provider query strings or domain coupling.

## Delivery phases

### A. Contracts and architecture

- [x] Reconcile bounded architecture/product/observability/backend/frontend/DevOps
  analysis.
- [x] Record trace storage and canonical query boundary ADRs.
- [x] Define OpenAPI contract before frontend implementation.
- [x] Define query limits, half-open range semantics and identity isolation.

### B. Backend, test-first

- [x] Add Traces domain/application concepts, query/probe ports and vendor-neutral
  errors.
- [x] Add Tempo adapter, module activation, health, REST mapping and self-telemetry.
- [x] Add unit, adapter, integration/API and ArchUnit coverage.

### C. Runtime slice

- [x] Add pinned Tempo, local filesystem persistence and Collector trace export.
- [x] Extend the demo only for deterministic success, controlled error and latency
  trace scenarios.
- [x] Add semantic trace ingestion/search/detail smoke verification.

### D. Frontend

- [x] Add `/traces` search/list/detail flow with loading, empty and failure states.
- [x] Add a readable hierarchy/waterfall using span offset/duration/error status.
- [x] Add Metrics → Traces context-preserving navigation and tests.

### E. Verification and documentation

- [x] Run complete backend, frontend, Compose and regression smoke gates.
- [x] Obtain independent review; fix all BLOCKER/HIGH findings.
- [x] Update remaining implementation-facing documentation truthfully.
- [ ] Obtain authoritative GitLab CI confirmation from the project owner.

## Local verification evidence

- Backend clean verification passes with 85 tests, nine ArchUnit rules, PMD,
  SpotBugs and Find Security Bugs.
- Frontend clean install, 34 Vitest tests, type checking, lint and production build
  pass with zero unhandled test errors.
- Compose configuration and pinned Collector/Tempo configuration validation pass;
  all six services become healthy.
- Collector self-observability, Metrics, and Traces semantic smoke scripts pass. The
  trace smoke verifies exact identity/range isolation, persistence, success/error/
  latency scenarios, hierarchy, IDs, details, and frontend proxy routes.
- Independent review reported no blockers. Its disabled-module UI, sub-second upper
  bound, and carried-range HIGH findings were fixed and regression-tested. Bounded
  service discovery remains documented medium technical debt.

## Acceptance criteria

- Collector persists deterministic successful, controlled-error and latency demo
  traces in Tempo.
- Trace services/search return only explicitly monitored telemetry matching the exact
  identity tuple and half-open requested range.
- Search returns at most 50 deterministically ordered summaries with valid trace IDs,
  root operation, duration >= 0, span count > 0 and correct error indication.
- Detail returns the requested trace only, complete available spans, valid IDs,
  parent-child links, deterministic hierarchy/timing and expected error semantics.
- Invalid ID/range, missing trace, disabled module and unavailable storage return
  distinct stable outcomes without backend details.
- Traces health is a bounded real backend probe; failure is visible without breaking
  module inventory or platform availability.
- The UI distinguishes loading, no traces, unavailable storage, invalid/not-found,
  trace summaries and span timing/error states.
- Metrics → Traces preserves service namespace/name, environment and absolute range.
- Existing Metrics and self-observability verification remains green.

## Definition of done and status rule

Local completion requires passing backend tests/ArchUnit/PMD/SpotBugs/Find Security
Bugs, frontend tests with zero unhandled errors/typecheck/lint/build, Compose startup,
semantic trace smoke and Metrics/self-observability regression verification, plus an
independent review with no unresolved BLOCKER/HIGH findings.

Even after all local gates pass, set status only to `READY FOR GITLAB REVALIDATION`.
The milestone becomes `COMPLETE` only after the project owner confirms the
authoritative GitLab CI pipeline is green for the candidate commit. Until then it is
not complete.
