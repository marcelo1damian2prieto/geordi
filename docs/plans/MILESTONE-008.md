# Milestone 008 — Error Budget & Burn Rate Foundation

Status: READY FOR GITLAB REVALIDATION

## Objective

Extend Geordi's existing SLO bounded context with trustworthy, current-window error
budget and burn-rate evidence. For every on-demand SLO evaluation, operators can see
the allowed bad-event ratio, the observed bad-event ratio, the dimensionless burn-rate
multiple, the exact evidence window, and whether the calculation is available.

This milestone derives evidence from the existing configuration-backed SLO definition
and canonical Metrics request-outcome measurement. It adds no storage, scheduler,
alert engine, notification system, incident lifecycle, or long-period budget accounting.

## Reconciled product and architecture contract

Milestone 8 remains inside the `slos` module. One evaluation captures one
`evaluatedAt`, creates one exact half-open range, performs one canonical request-outcome
measurement, and returns both M7 objective status and M8 burn evidence from that same
snapshot. The frontend must not combine separate evaluation queries with independently
captured ranges.

For whole-window request count `N`, HTTP 5xx count `E`, and target `T`:

| SLI | Observed SLI | Allowed bad ratio |
| --- | --- | --- |
| `AVAILABILITY` | `(N - E) / N` | `1 - T` |
| `ERROR_RATE` | `E / N` | `T` |

For both supported request-based SLIs, `observedBadRatio = E / N`. When the allowed
bad ratio is positive, `burnRate = observedBadRatio / allowedBadRatio`. API/domain
values are ratios; only presentation code formats them as percentages. Burn rate is a
dimensionless multiplier and has no alert classification in this milestone.

Burn evidence has the closed status `AVAILABLE` or `UNAVAILABLE`. Valid finite
`N > 0`, `0 <= E <= N`, and a positive allowed bad ratio produces an available finite
burn rate. `E = 0` is valid and produces burn rate zero. Evidence failures preserve
M7's bounded reasons. A zero allowed bad ratio produces `UNAVAILABLE` with
`ZERO_ALLOWED_BAD_RATIO`, while preserving a valid parent SLO evaluation and observed
bad ratio. NaN and infinity are never domain or API values.

Only the SLO definition's configured `PT5M`, `PT15M`, `PT1H`, or `PT6H` window is
evaluated. Fast/slow pairs are deferred because the repository contains no justified
window policy and they would multiply existing bounded provider fan-out and introduce
partial-window semantics.

## Execution plan

1. [x] Confirm the clean M1-M7-complete baseline, inspect M7 formulas, exact identity,
   windows, no-data/provider-failure behavior, Metrics boundary, UI navigation,
   self-observability, semantic smoke, and authoritative GitLab order/timeouts.
2. [x] Reconcile bounded architecture, product, observability, backend, frontend, and
   DevOps analyses before production implementation.
3. [x] Define the additive OpenAPI contract and record the SLI-aware, atomic-snapshot,
   zero-budget decision in ADR-016.
4. [x] Implement a pure SLI-aware domain policy and enriched evaluation test-first,
   retaining exact objective comparison and M7 unavailable semantics.
5. [x] Expose burn evidence through the existing evaluation response and add bounded,
   low-cardinality self-observability.
6. [x] Extend `/slos` with explicit allowed/observed bad ratios, burn multiplier,
   exact range, accessible unavailable reasons, and stale-evidence protection.
7. [x] Add an isolated deterministic burn workload and semantic PowerShell smoke that
   independently recomputes persisted Metrics evidence, then wire it after the SLO
   regression smoke in GitLab CI.
8. [x] Synchronize product, architecture, deployment, API, and technical-debt docs.
9. [x] Run the complete local CI equivalent, all regression smokes, burn smoke,
   cleanup verification, and `git diff --check`.
10. [x] Obtain independent read-only review, fix every BLOCKER/HIGH finding, and rerun
    affected verification.

## Acceptance criteria

- Both supported SLI directions derive the correct allowed bad ratio through one
  canonical policy.
- Objective status, observed bad ratio, and burn rate come from one exact service,
  environment, namespace, and absolute range measurement.
- Zero, fractional, exactly-one, and greater-than-one burn rates are correct and finite.
- Disabled, no-traffic, missing-count, invalid-telemetry, provider-failure, and
  zero-allowed-ratio outcomes are explicit and never become zero burn.
- VictoriaMetrics, MetricsQL/PromQL, stored instrument names, and provider DTOs remain
  confined to Metrics infrastructure.
- The API and `/slos` explain ratio versus percentage semantics and preserve the exact
  Service Investigation context without stale data.
- Self-observability uses only bounded result, reason, and SLI-type attributes.
- Backend/frontend quality gates, deployment validation, M1-M7 regression smokes, the
  independent burn smoke, cleanup, and independent review pass with no unresolved
  BLOCKER/HIGH findings.
- The Burn Rate smoke is mandatory in authoritative GitLab CI.

## Non-goals

No budget-remaining percentage, compliance period, evaluation history, persistence,
background evaluation, multi-window alert rule, alert lifecycle, routing, notification,
on-call/escalation, incident management, arbitrary expression/query language,
anomaly/ML/AI behavior, automatic remediation, or Milestone 9 functionality.

## Verification and review

The complete local CI-equivalent build passed with 161 backend tests, ArchUnit, PMD,
SpotBugs/Find Security Bugs, 104 frontend tests, type checking, lint, production build,
deployment configuration validation, and every M1-M8 semantic smoke. A clean-volume
post-review rerun passed the SLO and Burn Rate smokes, including exact independent
provider recomputation, provider outage/recovery, and cleanup. Independent re-review
reported no remaining BLOCKER or HIGH finding. The authoritative GitLab pipeline has
not yet been revalidated by the project owner.

## Status rule

Local success can move this plan only to `READY FOR GITLAB REVALIDATION`. Milestone 8
must not be marked `COMPLETE` until the project owner explicitly confirms the
authoritative GitLab pipeline is green. Any mandatory local failure leaves it
`NOT READY`.
