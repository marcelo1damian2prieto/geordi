# Alert Evaluation Architecture

Status: MILESTONE 9 COMPLETE

## Scope

Alert Evaluation answers whether one explicit deployment-managed condition is currently
satisfied by trustworthy canonical reliability evidence, and why. It is an on-demand,
side-effect-free evaluation capability—not notification delivery, an alert lifecycle,
an incident manager, a scheduler, or a generic rule engine.

Milestone 10 composes this unchanged stateless boundary into a separate explicit,
state-changing lifecycle use case. The M9 GET endpoint remains side-effect-free and
does not read or mutate lifecycle state; see `ALERT_LIFECYCLE.md`.

```text
read-only YAML policies
          |
          v
Alert Evaluation -> alerts-owned burn evidence port -> SLO/Burn evaluation
          |                                             |
          v                                             v
read-only REST / React                         canonical Metrics -> provider adapter
          |
          `-- exact identity/range --> existing Service Investigation
```

## Module and dependency boundary

`io.geordi.alerts.domain` owns policy, condition, evidence, status, and bounded reason
values. `io.geordi.alerts.application` owns catalog/query/evaluation use cases and the
outbound burn-evidence and SLO-reference ports. Web, YAML, SLO composition, telemetry,
and Spring code are adapters.

Only the SLO composition and Spring adapters may reference the SLO boundary. Alerts
domain/application code does not depend on Spring, OpenTelemetry SDKs, HTTP clients,
Metrics, SLO, Traces, Logs, Service Map, provider adapters, persistence, or notification
infrastructure. Existing contexts do not depend on alerts.

## Policy catalog

The version-controlled YAML catalog is mounted read-only and loaded as one immutable
startup snapshot. It contains at most 50 policies. Each policy has a stable lowercase
slug id, bounded name and optional description, enabled flag, referenced SLO id, and one
`BURN_RATE_ABOVE` condition with a non-negative finite public-number-safe threshold.
Unknown fields, duplicate ids, invalid values/types, overflow, positive underflow, and
unknown SLO references fail startup atomically.

Policy identity does not duplicate service identity or a window. Those belong to the
referenced SLO and arrive with its canonical evidence, preventing conflicting context.
The API is read-only and changes require restart/redeployment.

## Evaluation semantics

For M8 burn evidence status `AVAILABLE`, M9 compares the canonical `BigDecimal` value:

| Canonical burn evidence | Result |
| --- | --- |
| `burnRate < threshold` | `CONDITION_NOT_MET` |
| `burnRate == threshold` | `CONDITION_MET` |
| `burnRate > threshold` | `CONDITION_MET` |
| M8 `UNAVAILABLE` | `UNAVAILABLE` with the mapped bounded reason |

Valid burn zero is evidence. It is `CONDITION_NOT_MET` for any positive threshold. A
zero threshold is valid and therefore any available non-negative burn, including zero,
meets the inclusive condition.

M8 unavailability is never converted to zero or healthy. Disabled SLO, no traffic,
missing counts, invalid telemetry, Metrics failure, and zero allowed bad ratio all remain
alert `UNAVAILABLE`. A disabled alert policy returns `UNAVAILABLE/DISABLED` and calls no
SLO evaluator.

An enabled result preserves the canonical SLO id, exact service name/nullable namespace/
environment, configured window, exact half-open `[from,to)` interval, `evaluatedAt`, and
observed burn rate when available. No second clock or provider query exists.

## API, UI, and investigation

`GET /api/alert-policies` lists definitions. `GET
/api/alert-policies/{policyId}/evaluation` returns one explainable current snapshot;
unavailable outcomes are HTTP 200 domain results and unknown ids are 404 errors.

`/alert-evaluations` shows explicit `Condition met`, `Condition not met`, or
`Unavailable` text, never firing/resolved or delivery language. It hides stale evidence
while policy/evaluation context refreshes and constructs Investigation navigation only
from the returned service identity and exact range.

## Self-observability and bounds

Low-cardinality telemetry records attempts, result count, unexpected failures, and
duration with only closed condition type, result status, and optional bounded reason.
Policy/SLO identity, service context, thresholds, burn values, timestamps, provider
syntax/payloads, and exception text are excluded.

The 50-policy cap, one condition type, single inherited window, per-policy on-demand
endpoint, and lack of persistence/background work keep evaluation bounded. The alerts
module health check verifies catalog/evidence wiring and issues no provider probe.

## Authoritative validation

The authoritative GitLab pipeline passed the Service Map, SLO, Burn Rate, and Alert
Evaluation gates. M9 ran
`pwsh -File ./scripts/verify-alert-evaluation.ps1 -TimeoutSeconds 150` and verified the
catalog, self-contained traffic, independent exact-window zero/not-met and elevated/met
comparison evidence, disabled/no-traffic/zero-budget behavior, identity/range/threshold
preservation, provider-neutral API, Investigation context, and bounded telemetry.

The Burn Rate gate owns the relevant VictoriaMetrics outage/recovery exercise. Alert
Evaluation consumes that canonical boundary, so its smoke intentionally avoids a second
expensive outage scenario.
