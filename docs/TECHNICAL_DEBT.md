# Technical Debt

This document tracks non-blocking technical debt identified during milestone validation.
Entries do not change the completion status of the milestone in which they were detected.

## ECharts bundle and Service Map lazy chunk

- **Status:** Pending / Non-blocking
- **Detected in:** Milestone 2
- **Description:** The modular ECharts integration produces a main production chunk of
  approximately 774 kB (258 kB gzip), above Vite's default 500 kB advisory threshold.
- **Current impact:** The Metrics route still imports chart code in the main application
  bundle. The new Service Map graph uses ECharts but is isolated in a route-level lazy
  `/service-map` chunk, so it does not enlarge the initial application route bundle.
- **Follow-up:** Measure the lazy Service Map chunk and evaluate route-level lazy
  loading/code splitting for `/metrics` during frontend performance hardening. Do not
  add another chart wrapper dependency solely to suppress the advisory.

## Mockito / ByteBuddy dynamic agent loading

- **Status:** Pending / Non-blocking
- **Detected in:** Milestone 1.1
- **Description:** Mockito uses self-attachment and dynamic agent loading to enable
  inline mocking through ByteBuddy.
- **Evidence:** Tests emit warnings from Mockito and the JDK. Mockito states that
  self-attachment will no longer work in future JDK releases, while the JDK states that
  dynamic agent loading will be disallowed by default in a future release.
- **Current impact:** No functional impact. Tests pass and the Milestone 1.1 pipeline
  completes successfully.
- **Future risk:** A future JDK update may cause tests that depend on inline mocking to
  stop working if Mockito continues to rely on self-attachment.
- **Proposed solution:** Evaluate Mockito's officially recommended configuration for
  running Mockito as a Java agent during tests, avoiding reliance on dynamic
  self-attachment.
- **Priority:** Low / Medium
- **Recommended timing:** Address during a future Java stack update or maintenance
  cycle, or before adopting a JDK version that disables this behavior.

This debt is not a defect in Milestone 1.1. The milestone remains successfully completed.

## Tempo bounded service discovery

- **Status:** Pending / Non-blocking
- **Detected in:** Milestone 3
- **Description:** Service discovery derives exact identity tuples from a bounded Tempo
  search because independent tag-value APIs cannot safely reconstruct tuples.
- **Current impact:** The implementation prevents cross-service identity combinations,
  but a very high-cardinality window can omit a low-volume service after the fixed
  provider/result bound is reached.
- **Follow-up:** Introduce a canonical service catalog only when scale evidence justifies
  it; do not couple Traces discovery to Metrics or cross-product independent tag values.
- **Priority:** Medium

## Alert-policy catalog lifecycle

- **Status:** Planned / Deliberate Milestone 9 limitation
- **Detected in:** Milestone 9 implementation
- **Description:** Alert policies are intentionally version-controlled YAML mounted
  read-only and validated as an immutable startup snapshot. M9 supports no runtime CRUD,
  reload, audit history, concurrent writers, or policy history.
- **Current impact:** Policy changes require restart/redeployment. This keeps the first
  condition-evaluation capability deterministic and avoids an unauthenticated mutable
  control plane.
- **Follow-up:** Add authenticated policy management, concurrency semantics, auditability,
  and a replaceable durable store together only if operational policy management is
  required.
- **Priority:** Medium

## Alert Evaluation scope bounds

- **Status:** Planned / Deliberate Milestone 9 limitation
- **Detected in:** Milestone 9 implementation; updated in Milestone 10
- **Description:** M9 is limited to one canonical `BURN_RATE_ABOVE` condition evaluated
  on demand from one inherited M8 configured window. It has no background scheduler,
  full lifecycle history, notification delivery, acknowledgement, silencing, escalation,
  topology inhibition, generic expression language, or multi-window burn policy.
- **Current impact:** A condition result is explainable evidence for operator attention,
  not a delivered page or incident. M10 now provides durable current firing/resolved
  state and the latest transition only; it intentionally provides no transition ledger.
  Policies that reference the same SLO may independently request the same bounded SLO
  evaluation.
- **Follow-up:** Add batching, scheduling, lifecycle history, notification delivery, and additional canonical
  conditions only after their product semantics, authorization, storage, and delivery
  guarantees are explicitly designed; do not infer them from M9 results.
- **Priority:** Medium

## Alert lifecycle persistence and execution bounds

- **Status:** Pending / Deliberate Milestone 10 limitation
- **Detected in:** Milestone 10 implementation
- **Description:** Current lifecycle state uses embedded file-backed H2 and optimistic
  compare-and-set in one backend process. Evaluation is explicit and on demand; there
  is no scheduler, history ledger, episode id, outbox, or delivery subsystem.
- **Current impact:** Restart-safe deduplication is limited to the configured named
  volume and single-node modular-monolith runtime. Deleting the volume explicitly resets
  state. Multiple backend replicas do not have a designed shared durability or
  distributed-transition guarantee.
- **Follow-up:** Select an external replaceable store and define multi-node concurrency,
  retention/history, scheduling, and transactional delivery only when deployment or
  product evidence requires each capability.
- **Priority:** Medium

## Metrics upper-bound semantics

- **Status:** Pending / Non-blocking
- **Detected in:** Milestone 4 architecture reconciliation
- **Description:** Traces explicitly applies half-open `[from,to)` containment, while
  the Metrics domain validates an ordered maximum-six-hour range and forwards both
  bounds without documenting equivalent half-open containment.
- **Current impact:** Service Investigation sends identical absolute bounds to both
  signals, but documentation must not claim identical storage-boundary inclusion.
- **Follow-up:** Clarify and contract-test Metrics boundary semantics when a real
  boundary-sensitive use case or provider replacement requires it.
- **Priority:** Low

## Loki service-discovery response bound

- **Status:** Pending / Non-blocking
- **Detected in:** Milestone 5 independent review
- **Description:** Loki's `/series` endpoint accepts a selector and time bounds but no
  documented result-limit parameter. Geordi restricts discovery to monitored streams
  in a maximum six-hour window and returns at most 200 distinct canonical identities,
  but the adapter must materialize the provider response before applying that cap.
- **Current impact:** The four-label local/MVP topology keeps the practical response
  small. A deployment with a very large service/environment population could consume
  disproportionate response memory during discovery.
- **Follow-up:** Introduce a bounded canonical service catalog or a provider with
  server-side pagination only when scale evidence justifies it; do not reconstruct
  identity tuples by cross-producting independent label-value queries.
- **Priority:** Medium

## Service Map bounded trace-detail fan-out

- **Status:** Pending / Non-blocking
- **Detected in:** Milestone 6 implementation
- **Description:** Service Map selects bounded monitored CLIENT-bearing candidate traces,
  then derives edges only after up to 50 complete trace-detail reads and canonical direct
  CLIENT-parent-to-SERVER-child post-filtering. Retrieval is capped at eight concurrent
  requests and one 10-second budget, but this remains a provider fan-out rather than a
  single dependency-evidence query.
- **Current impact:** The fan-out cannot grow with an unbounded result set and returns
  explicit truncation when the candidate cap is exceeded. At larger trace volumes, its
  fixed request cost may still be material.
- **Follow-up:** Measure production-like trace volume and consider a provider capability
  that returns the same canonical direct CLIENT-to-SERVER evidence in one bounded query;
  do not add a topology cache, graph database, or generic relationship engine without
  scale evidence.
- **Priority:** Medium

## SLO catalog restart lifecycle

- **Status:** Pending / Deliberate Milestone 7 limitation
- **Detected in:** Milestone 7 implementation
- **Description:** SLO definitions are a version-controlled YAML file mounted read-only
  into the backend. The catalog is immutable after startup and has no runtime CRUD or
  dynamic reload.
- **Current impact:** Definition changes require restart/redeployment. The approach is
  deterministic and avoids an unauthenticated mutation surface, but it is not a mutable
  multi-operator management plane.
- **Follow-up:** Introduce authenticated mutation, concurrency semantics, auditability,
  and a replaceable durable store together only when runtime management is required.
- **Priority:** Medium

## SLO long-window accounting

- **Status:** Pending / Deliberate Milestone 8 limitation
- **Detected in:** Milestone 7 implementation; updated in Milestone 8
- **Description:** Evaluation supports only `PT5M`, `PT15M`, `PT1H`, and `PT6H` current
  windows and stores no evaluation history.
- **Current impact:** M8 now derives allowed/observed bad ratios and burn rate for one
  configured current window, but Geordi still cannot report 7/28/30-day compliance,
  calendar-period objectives, or remaining error budget. It must not present a
  current-window burn result as long-period SLO compliance or budget accounting.
- **Follow-up:** Design long-period accounting and retention only with explicit product
  semantics and storage evidence; do not extrapolate it from current evaluations.
- **Priority:** Medium

## SLO request-count provider semantics

- **Status:** Pending / Bounded provider limitation
- **Detected in:** Milestone 7 implementation
- **Description:** The VictoriaMetrics adapter derives whole-window request and 5xx
  counts with counter `increase` at the exclusive evaluation end. Counter sampling,
  scrape/export cadence, reset handling, and provider extrapolation can yield fractional
  estimates near window boundaries. A successful response with a request component and
  no 5xx component is canonicalized to an explicit zero error count.
- **Current impact:** Formulas remain directionally and dimensionally correct, but the
  observed counts have VictoriaMetrics/OpenTelemetry counter-estimation precision rather
  than event-ledger precision.
- **Follow-up:** Preserve adapter contract tests and semantic smoke comparison against an
  independent provider query. Reassess the provider mapping before claiming longer-term
  accounting or when replacing VictoriaMetrics.
- **Priority:** Medium

## SLO frontend evaluation fan-out

- **Status:** Pending / Bounded
- **Detected in:** Milestone 7 implementation
- **Description:** `/slos` issues one evaluation request for every enabled definition.
  The catalog is capped at 50, so the fan-out is bounded but can still produce 50 backend
  and VictoriaMetrics queries during initial load or refresh.
- **Current impact:** The local three-definition catalog is small. A maximally populated
  catalog can create a short burst of concurrent provider work.
- **Follow-up:** Measure realistic catalog sizes and add bounded concurrency or a
  canonical batch-evaluation boundary only when evidence justifies it; do not add a
  scheduler or cache speculatively.
- **Priority:** Medium

## Alert lifecycle store initializes with the modular monolith

- **Status:** Pending / Bounded modular-monolith constraint
- **Detected in:** Milestone 10 implementation
- **Description:** Spring DataSource and Flyway auto-configuration initialize the local
  alert lifecycle store as platform runtime infrastructure even when the optional
  `alerts` capability is disabled. Disabling Alerts removes its catalog, API, lifecycle,
  and adapter beans, but does not remove the embedded database startup dependency.
- **Current impact:** The default H2 file store has no external availability dependency,
  and its directory must remain writable for every backend deployment. A custom or
  externally hosted lifecycle JDBC URL can therefore still prevent a deliberately
  Alerts-disabled backend from starting.
- **Follow-up:** If deployments require removal of the storage dependency together with
  the capability, conditionally own DataSource/Flyway infrastructure without changing
  startup order or migration guarantees for enabled Alerts.
- **Priority:** Medium
