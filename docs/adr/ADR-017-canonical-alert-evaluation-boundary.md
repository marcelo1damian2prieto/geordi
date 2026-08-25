# ADR-017: Canonical Alert Evaluation over Burn-Rate Evidence

Status: ACCEPTED

## Context

Milestone 8 produces one provider-neutral, current-window burn snapshot inside an SLO
evaluation. Milestone 9 must decide whether an explicit policy condition deserves current
operator attention without duplicating burn formulas, introducing provider queries, or
implying notification delivery or persistent lifecycle state.

Alert policy and result semantics are distinct from SLO calculation. Future notification
delivery should consume a canonical alert evaluation rather than couple directly to SLO
or Metrics infrastructure.

## Decision

Create a dedicated `alerts` logical bounded context inside the existing modular monolith.
It owns deployment-managed policy validation and the pure mapping:

```text
policy + canonical burn evidence + inclusive comparison = current alert evaluation
```

The alerts application owns a burn-evidence port. An outbound SLO composition adapter
calls `SloEvaluationUseCase` exactly once and maps its nested M8 burn snapshot into
alerts-owned values. Alerts domain/application code imports no SLO or Metrics types. The
adapter performs no `E/N`, allowed-bad-ratio, or burn-rate calculation and captures no
second time range.

The initial and only condition is `BURN_RATE_ABOVE`, defined as
`canonical burnRate >= threshold`. Equality is condition met. The comparator uses the
canonical M8 `BigDecimal`, not frontend formatting. Thresholds are non-negative, finite,
and public-number safe; zero is valid. Valid burn zero compares normally.

Statuses are `CONDITION_MET`, `CONDITION_NOT_MET`, and `UNAVAILABLE`. Every unavailable
M8 burn outcome maps to `UNAVAILABLE` with a bounded reason. Disabled alert policies map
to `UNAVAILABLE/DISABLED` without evaluating their SLO. This is a stateless on-demand
result, not a firing/resolved alert instance.

Policies live in an immutable, version-controlled YAML catalog capped at 50. Startup
validation is atomic and includes unique ids, supported fields/type, valid thresholds,
and existing referenced SLOs. There are no write APIs, runtime reload, or persistence.

## Consequences

- VictoriaMetrics, MetricsQL/PromQL, provider DTOs, and request-outcome formulas remain
  outside the alerts core.
- Exact service identity, configured window, `[from,to)`, and `evaluatedAt` remain one
  coherent M8 snapshot.
- Future notification/lifecycle modules can depend on a stable provider-neutral alert
  result without changing current evaluation semantics.
- Multiple per-policy evaluations may repeat an SLO evaluation; the bounded catalog and
  existing per-resource API keep M9 small. A later measured batch need may group by SLO
  without adding a scheduler or cache.
- Policy changes require restart/redeployment.

Notification delivery, alert-instance persistence/history, scheduling, generic rules,
multi-window burn paging, incidents, acknowledgement, silencing, and escalation are
explicitly deferred.

