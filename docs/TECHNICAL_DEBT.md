# Technical Debt

This document tracks non-blocking technical debt identified during milestone validation.
Entries do not change the completion status of the milestone in which they were detected.

## Metrics view JavaScript bundle

- **Status:** Pending / Non-blocking
- **Detected in:** Milestone 2
- **Description:** The modular ECharts integration produces a main production chunk of
  approximately 774 kB (258 kB gzip), above Vite's default 500 kB advisory threshold.
- **Current impact:** Frontend build, tests, type checking and linting pass. Initial page
  download includes chart code even when the user opens only Platform Overview.
- **Follow-up:** Evaluate route-level lazy loading/code splitting for `/metrics` during
  frontend performance hardening. Do not add another chart wrapper dependency solely to
  suppress the advisory.

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
