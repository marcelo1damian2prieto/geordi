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
