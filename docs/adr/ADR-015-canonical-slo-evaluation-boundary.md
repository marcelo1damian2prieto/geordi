# ADR-015: Canonical SLO Evaluation Through Metrics

Status: ACCEPTED

## Context

Milestone 7 must evaluate service reliability without accepting provider queries or
coupling SLO definitions to VictoriaMetrics. The existing Metrics catalog includes HTTP
request count, HTTP error count, an error-rate chart series, and p95 latency. However,
the chart-oriented error rate uses a rolling resolution interval, and the latency series
does not prove whole-window request compliance. Neither is a safe general-purpose SLO
evaluation contract.

An SLO must also distinguish valid zero, no traffic, missing data, malformed telemetry,
and provider failure. The existing display-series path intentionally represents valid
absence as an empty series and is not sufficient by itself for that decision.

## Decision

The SLO bounded context evaluates only two canonical SLI types in Milestone 7:

- `AVAILABILITY`, calculated as `(N - E) / N` and met when the observed ratio is
  greater than or equal to the target; and
- `ERROR_RATE`, calculated as `E / N` and met when the observed ratio is less than or
  equal to the target.

`N` is the canonical whole-window HTTP request count and `E` is the canonical
whole-window HTTP 5xx request count for one exact monitored service identity. Both SLIs
derive from the same request-outcome measurement. Equality with the target is `MET`.

Targets and observed SLI values are dimensionless ratios in the inclusive range
`[0,1]`. Percentages are presentation formatting only; persisted definitions and REST
contracts never use an ambiguous `0..100` representation.

Supported evaluation windows are exactly:

- `PT5M`;
- `PT15M`;
- `PT1H`; and
- `PT6H`.

For one evaluation, `evaluatedAt` is captured once and the requested absolute interval
is `[evaluatedAt - window, evaluatedAt)`. Provider adapters own the translation of this
whole-window request and must contract-test their boundary behavior. Provider sampling
and counter extrapolation must not be described as greater precision than the backend
actually supplies.

The SLO application consumes an SLO-owned measurement port. An outbound Metrics
composition adapter calls a narrow, vendor-neutral Metrics application boundary that
returns the whole-window request outcome measurement. That Metrics boundary, rather
than the SLO module, owns the mapping to stored OpenTelemetry instruments. The existing
VictoriaMetrics adapter remains the only place that may translate the canonical request
into MetricsQL/PromQL or provider HTTP/JSON types.

Conceptually:

```text
SLO definition
      |
      v
SLO evaluator -> request-outcome measurement port
                       |
                       v
               SLO Metrics adapter
                       |
                       v
        canonical Metrics application boundary
                       |
                       v
             VictoriaMetrics adapter
```

The exact monitored identity is `service.name`, optional-but-exact
`service.namespace`, and `deployment.environment.name`, with
`geordi.telemetry.origin=monitored` applied by Metrics. An absent namespace means only
an absent namespace and never widens the query. No SLO path may query by service name
alone.

## Evaluation and absence semantics

Evaluation requires a finite request count `N > 0`. Milestone 7 adds no statistical
confidence model or higher minimum-traffic policy.

The canonical outcomes are:

| Measurement outcome | SLO outcome |
| --- | --- |
| Finite `N > 0`, finite `0 <= E <= N` | Calculate the selected SLI and compare it with the target |
| Finite `N = 0` | `UNAVAILABLE` with reason `NO_TRAFFIC` |
| Missing request count | `UNAVAILABLE` with reason `MISSING_REQUEST_COUNT` |
| Missing error count | `UNAVAILABLE` with reason `MISSING_ERROR_COUNT` |
| Negative, non-finite, malformed, or `E > N` | `UNAVAILABLE` with reason `INVALID_TELEMETRY` |
| Metrics timeout, query failure, or unavailable provider | `UNAVAILABLE` with reason `METRICS_UNAVAILABLE` |

A valid numeric zero is data and remains distinct from absence. The Metrics adapter may
canonicalize an absent provider error series to `E = 0` only when it can prove that the
successful response means no matching 5xx outcome for the same exact identity and
window. It must otherwise report missing error count. Malformed or non-finite provider
values are never silently converted to zero.

The evaluation statuses are exactly `MET`, `BREACHED`, and `UNAVAILABLE`. An unavailable
evaluation has no observed SLI value and carries a bounded reason code. Provider failure
is neither met nor breached. A disabled definition retains `enabled=false`; an explicit
evaluation request returns HTTP 200 with `UNAVAILABLE` and reason `DISABLED` without
querying Metrics. This keeps the read API deterministic while preserving lifecycle state
and avoiding a false reliability conclusion.

## Explicit exclusions

Milestone 7 does not support:

- latency or percentile SLOs;
- arbitrary metrics or expressions;
- PromQL, MetricsQL, provider labels, or provider DTOs in definitions, application
  commands, persistence, REST, or UI;
- scheduled/background evaluation;
- evaluation history, error budgets, burn rates, or compliance periods; or
- alerts, notifications, incidents, acknowledgement, or silencing.

## Consequences

- SLO formulas and threshold direction are small, explicit, and testable at equality
  and immediately around the target.
- Availability and error rate share one canonical request-outcome measurement and
  cannot drift into contradictory provider queries.
- Metrics remains responsible for OpenTelemetry instrument mapping and provider
  translation; SLOs remain replaceable and vendor-neutral.
- Existing chart-series APIs remain unchanged and are not treated as SLO-grade
  aggregates.
- No-traffic, invalid telemetry, and provider failure remain explainable but share the
  bounded public status `UNAVAILABLE`.
- A future latency SLO requires a separate decision based on telemetry that can prove
  the intended whole-window threshold semantics.
