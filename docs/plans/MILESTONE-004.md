# Milestone 004 — Lightweight Service Investigation

Status: COMPLETE

> The project owner confirmed that the authoritative GitLab pipeline is green. The
> implementation, local verification, independent review, and authoritative CI gate
> are complete.

## Objective

Deliver one service-centric workflow that lets an operator move from a suspected slow
or unhealthy service to matching RED/JVM metrics and relevant traces without rebuilding
service identity, environment, or time context.

## Product workflow

The bookmarkable `/investigate` route owns one canonical context:

- optional-but-exact `service.namespace`;
- required `service.name`;
- required `deployment.environment.name`;
- one absolute `from` and `to`, no wider than six hours.

The page shows fixed RED signals, available JVM/resource signals, recent traces,
slowest traces among the bounded recent results, and error traces. Trace links open the
existing Trace Detail and preserve a safe return path to the same investigation.

## Reconciled architecture

Composition remains frontend-only:

```text
React Service Investigation
    |-- Metrics services/series APIs
    `-- Traces services/search/detail APIs
```

No backend aggregation endpoint, Investigation backend module, shared Metrics/Traces
domain abstraction, ADR, new provider, or infrastructure is justified. Existing
Metrics and Traces contracts accept the same exact identity dimensions and absolute
bounds and already isolate provider failures.

The bounded request model is:

- when URL context is absent, independent Metrics and Traces service discovery whose
  exact identity tuples are unioned without manufacturing combinations;
- two non-overlapping batched Metrics series requests: five RED metrics and four
  JVM/resource metrics, each used for both latest values and trends;
- one normal Trace search used for Recent and the derived duration ordering;
- one `errorOnly=true` Trace search used for Error traces.

This preserves RED/JVM failure isolation without duplicating provider metric work,
avoids the Metrics overview/series overlap, and avoids a duplicate Trace request for
Slow traces.

## Context and data semantics

- Namespace omission means only the canonical absent namespace, never a wildcard.
- A complete valid URL context starts signal queries without waiting for discovery.
- Partial or malformed canonical URL state is invalid and must not silently become a
  fresh context.
- Preset changes create one new absolute interval and apply it to every signal.
- Refresh re-queries the same absolute interval rather than sliding it.
- Metrics and Traces receive identical absolute bounds. Traces documents a half-open
  `[from,to)` result contract; Milestone 4 does not make a stronger storage-boundary
  claim for Metrics.
- A returned numeric zero is evidence and remains visible. An absent metric/empty series
  is `No telemetry`, never synthesized as zero.
- Recent preserves backend newest-first order. Slow is labeled `Slowest among recent
  results` and sorts only the same bounded result set by duration; it is not a global
  policy or anomaly detector.

## Partial-data and failure semantics

RED Metrics, JVM/resource Metrics, recent traces, and error traces load and fail
independently. One valid section remains visible when another provider or query fails.
Disabled capabilities,
invalid requests, provider unavailability, malformed provider responses, timeouts,
empty results, and missing telemetry retain their existing signal-specific meanings.

Service discovery failures do not block a URL-seeded context. When no URL context is
present, each discovery failure is shown independently and any identities returned by
the other provider remain usable.

## Stale-data safety

Every signal query key includes the exact namespace/name/environment and both absolute
bounds; Trace keys also include `errorOnly`. Signal queries do not retain prior-context
data. On a service, environment, namespace, or range transition, old values and trace
IDs disappear while the new context loads. Discovery placeholder data is not treated
as current investigation evidence.

## Self-observability

No backend orchestration is added. Existing Metrics and Traces HTTP, query, provider
failure, latency, result-size, and probe telemetry observes every composed request and
retains `geordi.telemetry.origin=platform`. Service identities, raw provider queries,
trace IDs, response bodies, exception text, and other high-cardinality values remain
excluded. Frontend page-view telemetry is not introduced for this milestone.

Runtime audit showed that the Java agent's backend `HttpURLConnection`
auto-instrumentation emitted full provider URLs despite the safe custom instruments.
The local deployment disables only that outbound instrumentation. Inbound backend HTTP
spans and the low-cardinality Metrics/Traces adapter instruments remain enabled.

## Delivery plan

### A. Architecture and contracts

- [x] Inspect repository state, governing docs, existing slices, runtime, smoke, and CI.
- [x] Reconcile architecture, product, observability, backend, and frontend analyses.
- [x] Decide frontend composition and reject backend aggregation.
- [x] Define canonical URL, partial-data, slow-trace, and stale-data semantics.

### B. Frontend, test-first

- [x] Add strict absent/valid/invalid investigation-context tests and parsing.
- [x] Add presentation tests for bounded recent/slow/error trace subsets and immutable
  sorting.
- [x] Add `/investigate` route/navigation tests.
- [x] Add investigation acceptance tests for context consistency, partial failures,
  empty versus zero, navigation, and stale-data transitions.
- [x] Implement the concrete investigation screen using existing API clients/hooks and
  presentation components.
- [x] Add Metrics/Traces to Investigation links and context-aware Trace Detail return.

### C. Documentation and verification

- [x] Synchronize README, product, architecture, module, self-observability, frontend,
  and technical-debt documentation where repository evidence requires it.
- [x] Run backend clean verification including ArchUnit, PMD, SpotBugs, and Find
  Security Bugs.
- [x] Run frontend clean install, Vitest with zero unhandled errors, typecheck, lint,
  and production build.
- [x] Validate Compose and Collector/Tempo configuration.
- [x] Run existing self-observability, Metrics, and Traces semantic smoke scripts.
- [x] Obtain severity-ranked independent review and fix every BLOCKER/HIGH finding.

## Local verification evidence

- Backend Java 21 `clean verify`: 85 tests, including 9 ArchUnit tests; PMD passed;
  SpotBugs plus Find Security Bugs reported zero findings and zero errors.
- Frontend clean install: 278 packages audited with zero vulnerabilities; 54 Vitest
  tests passed with zero unhandled errors; typecheck and ESLint passed; production build
  passed with the existing ECharts chunk-size advisory.
- Collector 0.157.0 and Tempo 2.7.2 configuration validation passed.
- Compose configuration, fresh no-cache image build, and health-gated startup passed.
- OTLP, Metrics, and Traces semantic smoke scripts passed. Metrics and Traces passed
  again after the outbound URL telemetry mitigation.
- Post-mitigation telemetry contained zero provider `url.full` attributes, while safe
  adapter metric batches and inbound API spans remained present.
- Independent review found no BLOCKER. Its one HIGH discovery-state finding and one
  MEDIUM investigation-return-copy finding were fixed test-first; the remaining LOW
  fixture and documentation-status findings were also resolved.

## Acceptance criteria

1. `/investigate` exists and is bookmarkable with exact canonical context.
2. All Metrics and Trace requests use the same namespace/name/environment/bounds.
3. RED and available JVM/resource signals are visible.
4. Recent, error, and slowest-among-recent traces are visible.
5. Existing Trace Detail opens and returns with context preserved.
6. Metrics, recent traces, and error traces isolate loading, empty, and failure states.
7. Missing telemetry is not zero; returned numeric zero stays visible.
8. Service, namespace, environment, and range changes never display stale evidence.
9. No Metrics/Traces domain coupling, provider leakage, aggregation endpoint, generic
   query engine, Logs, full APM, or Milestone 5 work is introduced.
10. Existing backend, frontend, runtime, and semantic smoke quality gates remain green.
11. Documentation matches implementation and independent review has no unresolved
    BLOCKER/HIGH findings.

## Non-goals

No Logs, full APM, service/dependency maps, topology, alerts/SLOs, anomaly detection,
AI/RCA, dashboards or widgets, saved investigations, RUM, synthetics, profiling,
Kubernetes/infrastructure product work, exemplars, new stores, arbitrary provider query
languages, or generic cross-signal abstractions.

## Smoke decision

No new route-only smoke is planned. The existing Metrics and Traces scripts already
verify semantic identity/range/data contracts, while frontend acceptance tests can
verify actual cross-signal composition and navigation. A new HTTP-200-only route check
would not add meaningful semantic coverage.

## Definition of done and completion

Local readiness requires all implementation acceptance criteria, complete CI-equivalent
verification, semantic regression smokes, synchronized documentation, and independent
review with no unresolved BLOCKER/HIGH findings.

The local implementation reached `READY FOR GITLAB REVALIDATION` with all acceptance
criteria satisfied and no unresolved BLOCKER/HIGH findings. The project owner then
confirmed the authoritative GitLab pipeline was green, so Milestone 4 is `COMPLETE`.
