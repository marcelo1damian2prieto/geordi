# SLO Architecture

Status: MILESTONE 7 COMPLETE; MILESTONE 8 READY FOR GITLAB REVALIDATION

## Scope

The SLO bounded context provides the smallest trustworthy capability for defining and
evaluating current service-level objectives over Geordi's canonical Metrics. It is an
on-demand evaluation capability, not a notification system, incident manager, generic
rule engine, or long-period compliance product.

```text
Version-controlled YAML definitions
                 |
                 v
       read-only SLO catalog
                 |
                 v
GET /api/slos -> SLO evaluator -> canonical request outcomes -> Metrics -> VictoriaMetrics
       |
       v
React /slos -- exact identity and absolute range --> existing /investigate
```

VictoriaMetrics, MetricsQL/PromQL, stored metric names, provider labels, HTTP envelopes,
and provider response DTOs remain inside the Metrics outbound adapter. SLO definitions,
evaluation results, REST contracts, and the frontend contain none of them.

## Module boundary

`slos` is a compile-time Geordi module registered through module-owned Spring
configuration. Its module definition is always registered so inventory can distinguish
installed and disabled state. Capability beans and REST routes exist only when the SLO
module and its Metrics dependency are enabled.

The intended dependency direction is:

```text
SLO web/config/telemetry adapters -> SLO application -> SLO domain
SLO Metrics composition adapter -> canonical Metrics application boundary
Metrics provider adapter -> Metrics application/domain
```

SLO domain/application code does not depend on Spring, OpenTelemetry SDK
implementations, persistence frameworks, HTTP clients, VictoriaMetrics, Tempo, Loki,
Grafana, or provider query languages. Metrics does not depend on SLOs. SLOs have no
backend dependency on Traces, Logs, Service Map, or Service Investigation.

## Definition catalog

Milestone 7 definitions are deployment configuration. The authoritative YAML file is
version-controlled and mounted read-only into the backend. At startup the enabled
module validates the entire file and publishes one immutable catalog snapshot. Invalid
or duplicate definitions, unstable/missing identifiers, and a catalog larger than 50
definitions fail startup; partial catalogs are never served.

A definition contains:

- stable identifier;
- name and optional description;
- exact canonical service identity;
- `AVAILABILITY` or `ERROR_RATE` SLI type;
- target ratio in `[0,1]`, validated against the public finite-double evidence
  contract;
- one supported evaluation window; and
- enabled/disabled state.

The catalog exposes reads only. There is no runtime create/edit/delete API or UI,
dynamic reload, database, application-managed backup, audit history, or concurrent
writer behavior. Editing the file requires a backend restart or redeployment. See
ADR-014 for durability, concurrency, and replacement semantics.

## Canonical service and time context

Every definition selects one exact monitored resource tuple:

- required `service.name`;
- optional `service.namespace`, where omission means exact absence; and
- required `deployment.environment.name`.

Metrics additionally restricts the provider query to
`geordi.telemetry.origin=monitored`. Missing identity never becomes wildcard behavior.

Evaluation windows are the closed catalog `PT5M`, `PT15M`, `PT1H`, and `PT6H`. The
evaluator captures one `evaluatedAt`, derives one absolute requested range
`[evaluatedAt - window, evaluatedAt)`, and returns that same range in the result. The
range is also the navigation context for Service Investigation.

## Supported SLI semantics

One canonical Metrics measurement supplies:

- `N`: whole-window HTTP request count; and
- `E`: whole-window HTTP 5xx request count.

The supported SLIs are:

| SLI | Observed ratio | Objective comparison |
| --- | --- | --- |
| `AVAILABILITY` | `(N - E) / N` | `observed >= target` |
| `ERROR_RATE` | `E / N` | `observed <= target` |

Targets and observed values are ratios in `[0,1]`; percentages exist only in UI
formatting. Equality is `MET`. Latency is excluded because the implemented chart p95
does not prove whole-window threshold compliance.

The JSON numeric surface is an IEEE-754 finite `double`. Nonzero targets and derived
values must remain nonzero in that representation. Definitions whose positive allowed
ratio could produce an unrepresentable burn rate are rejected. Objective status still
uses exact cross-multiplication, independent of returned-value rounding.

The SLO evaluator does not consume the latest point from the Metrics chart API. It uses
a dedicated whole-window, vendor-neutral request-outcome boundary. The SLO-owned
outbound port and Metrics composition adapter keep Metrics application types and
provider failures outside the SLO domain.

## Status, no-data, and failure semantics

Evaluation statuses are:

- `MET`: valid evidence satisfies the configured comparison;
- `BREACHED`: valid evidence does not satisfy it; and
- `UNAVAILABLE`: sufficient valid evidence could not be obtained.

`UNAVAILABLE` carries one bounded reason such as `NO_TRAFFIC`,
`MISSING_REQUEST_COUNT`, `MISSING_ERROR_COUNT`, `INVALID_TELEMETRY`, or
`METRICS_UNAVAILABLE`. It has no observed SLI value.

Evaluation requires finite `N > 0` and finite `0 <= E <= N`. Numeric zero remains valid
data: `E = 0` produces availability `1` and error rate `0`. By contrast, `N = 0` is no
traffic and cannot establish reliability. Missing counts, negative/non-finite values,
`E > N`, malformed provider data, timeouts, and provider failures never become zero,
`MET`, or `BREACHED`.

An absent provider error series may become canonical `E = 0` only when the Metrics
adapter can prove that the successful provider response represents no matching 5xx
outcome for the same identity and window. Otherwise the measurement is missing and the
evaluation is unavailable. ADR-015 defines the complete table.

Disabled definitions remain visible with `enabled=false`. The frontend does not request
their evaluation. If the evaluation API is called directly, it performs no Metrics query
and returns HTTP 200 with `UNAVAILABLE` and reason `DISABLED`. The reason preserves the
definition lifecycle distinction without inventing an observed reliability value.

## Current-window error-budget burn (Milestone 8)

M8 derives one atomic burn snapshot within the existing on-demand SLO evaluation. It
does not create a second endpoint, burn store, scheduler, or provider query path. The
snapshot uses the definition's same exact monitored identity, captured `evaluatedAt`,
and returned half-open `[from,to)` configured window as the parent SLO result.

`allowedBadRatio` is SLI-aware: for `AVAILABILITY` it is `1 - target`; for `ERROR_RATE`
it is `target`. Given valid finite `N > 0` and `0 <= E <= N`, `observedBadRatio` is
always `E/N`, and dimensionless `burnRate` is
`observedBadRatio / allowedBadRatio`. Ratios are canonical API/domain values in `[0,1]`;
the UI may render them as percentages, while burn rate is rendered as a multiplier.
Returned derived values use 12 significant decimal digits with half-up rounding, and
burn is calculated directly from the unrounded counts. Positive evidence is never
rounded to zero. If a positive measurement ratio is below the finite-double contract,
the result is `UNAVAILABLE/INVALID_TELEMETRY` rather than fabricated zero.

Burn status is a separate closed pair: `AVAILABLE` or `UNAVAILABLE`. Valid evidence and
a positive allowed bad ratio produce `AVAILABLE`, including valid zero-error evidence
with a burn rate of zero. Disabled/no-traffic/missing/invalid/provider-unavailable
parent evidence produces `UNAVAILABLE` with the corresponding bounded M7 reason. A
zero allowed bad ratio produces `UNAVAILABLE/ZERO_ALLOWED_BAD_RATIO`; it preserves the
valid observed bad ratio but emits no burn number. NaN and infinity are never domain,
API, or UI values.

This is current-window consumption evidence, not error-budget accounting. It must never
be described as budget remaining, exhausted monthly budget, or compliance-period SLO
performance. M8 supports no fast/slow multi-window policy, alerts, notifications,
incidents, history, persistence, or scheduler.

## REST and frontend

The read-only API is:

- `GET /api/slos` for the definition catalog;
- `GET /api/slos/{id}` for one definition; and
- `GET /api/slos/{id}/evaluation` for its on-demand current evaluation.

Evaluation-time no-data, provider failure, or a disabled definition is a representable
HTTP 200 evaluation response with status `UNAVAILABLE`; it is not disguised as a
successful SLI. Invalid requests and unknown identifiers remain distinct API errors.

The `/slos` UI presents name, exact identity, SLI, target, observed value when available,
window, status, and unavailable reason. M8 additionally presents allowed and observed
bad-event ratios, burn rate, its textual accessible availability state, and bounded
unavailability explanation. Status uses text and accessible semantics rather than color
alone. Query keys include the SLO identifier and all returned evaluation context; a
previous objective's status or burn evidence is never presented as current while another
is loading.

“Investigate service” opens the existing `/investigate` route with the exact namespace,
service name, environment, and absolute evaluation range. The SLO view does not embed or
duplicate Metrics, Traces, Logs, or Service Map investigation panels.

## Health and self-observability

The SLO module validates catalog availability and canonical Metrics boundary wiring. It
does not issue a second VictoriaMetrics health query. Runtime provider reachability
remains the Metrics module's responsibility, while an on-demand SLO evaluation maps a
Metrics failure to `UNAVAILABLE`.

Low-cardinality platform telemetry records evaluation count, duration, result status,
bounded failure reason, catalog-load failure, and M8 burn-result availability/reason.
The closed SLI type and window may be used as bounded attributes. SLO identifiers,
names, service identity, descriptions, targets, ratios, burn rate, timestamps, provider
expressions, response bodies, and exception messages are never metric labels.

## Bounds and replaceability

The 50-definition startup limit, four fixed windows, two SLI types, exact service
identity, and on-demand evaluation keep provider work and public semantics bounded.
There is no scheduler, queue, background worker, or stored evaluation history.

The definition catalog is replaceable behind its read-only port. A future mutable store
requires a new persistence/security decision rather than changing the current YAML
adapter implicitly. The Metrics provider remains replaceable behind the canonical
request-outcome boundary. Neither replacement changes SLO formulas or public status
semantics.

## Explicit non-goals

M8 adds no latency SLOs, arbitrary queries, generic alert rules, notifications, incident
lifecycle, acknowledgement, silencing, maintenance windows, escalation, on-call
scheduling, evaluation history, error-budget remaining, long calendar periods, anomaly
detection, AI/RCA, or Milestone 9 capability. M8 is **READY FOR GITLAB REVALIDATION**
after mandatory local verification and independent review passed without a remaining
BLOCKER or HIGH finding; only authoritative GitLab green and project-owner confirmation
can make it complete.
