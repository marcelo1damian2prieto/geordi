# Service Investigation Architecture

Status: IMPLEMENTED THROUGH MILESTONE 7; MILESTONE 7 VERIFICATION PENDING

## Scope

Service Investigation is a thin frontend workflow over the implemented Metrics, Traces,
and Logs bounded contexts. It is not a backend module, an APM domain, a dashboard
engine, or a cross-signal query service.

```text
                         canonical TelemetryContext
                                    |
React /investigate -----------------+------------------+------------------+
       |                            |                  |
       v                            v                  v
Metrics public REST          Traces public REST   Logs public REST
       |                            |                  |
       v                            v                  v
Metrics application          Traces application   Logs application
       |                            |                  |
       v                            v                  v
VictoriaMetrics adapter      Tempo adapter        Loki adapter
```

Metrics, Traces, and Logs remain independent. Backend ArchUnit rules prohibiting
cross-signal dependency directions remain the architectural guardrail.

## Canonical context

The frontend's signal-neutral `TelemetryContext` contains an exact composite service
identity and one absolute range. The URL uses `serviceName`, optional
`serviceNamespace`, `environment`, `from`, and `to`. Namespace omission is exact
absence, never wildcard behavior. Malformed or partial context is rejected rather than
silently widened or replaced.

One context transition creates one absolute interval, and every request receives those
same serialized bounds. Traces applies its documented half-open `[from,to)` semantics;
the composition layer does not invent a stronger Metrics storage-boundary guarantee.

## Request composition

When no valid URL identity exists, the frontend independently discovers Metrics, Trace,
and Logs services and unions complete identity tuples. It never intersects dimensions or
creates a cross-product of service, namespace, and environment.

For an active context it performs bounded evidence queries:

1. one batched Metrics series request for the five RED metrics;
2. one batched Metrics series request for the four JVM/resource metrics;
3. one normal bounded Trace search for Recent and the derived duration ordering;
4. one error-only bounded Trace search.
5. one bounded Logs search for recent records.

The two Metrics groups are non-overlapping, so this adds failure isolation without
duplicating provider metric queries or using the overlapping overview endpoint.

Latest metric values are derived from returned points, so valid zero remains distinct
from an empty series. Slow traces are the duration-descending subset of the same recent
search response and are labeled `Slowest among recent results`; they do not establish a
global threshold or a whole-window ordering guarantee.

## Failure isolation

The page never gates all content on a combined promise. Discovery, Metrics, recent
traces, error traces, and Logs have independent loading, empty, failure, and retry
behavior.
A provider failure removes neither valid evidence nor controls belonging to another
signal. Missing JVM telemetry and no error traces are normal empty states, not platform
or provider failures.

## Stale-data protection

Signal query keys contain namespace, service name, environment, `from`, `to`, and any
trace filter. Prior-context signal data is not used as placeholder data. URL context is
the active identity after initialization; changing a selector or range atomically
changes the entire context, so old values and trace identifiers cannot be presented as
current.

## Trace navigation

Investigation links reuse `/traces/{traceId}` and add only canonical context plus a
small enumerated origin marker. Trace Detail reconstructs a safe `/investigate` return
target from validated canonical parameters. It never accepts or echoes an arbitrary
return URL. Ordinary Trace-search navigation remains unchanged.

## Service Map navigation

Service Map remains a separate trace-derived capability. Its node action opens this
existing `/investigate` workflow with the exact selected node identity and unchanged
absolute range; it does not embed or duplicate Investigation. Its bounded edge evidence
opens existing Trace Detail with validated callee identity, the same range, and the
enumerated `service-map` origin. Service Map failure neither changes this workflow nor
creates a backend cross-signal dependency.

## SLO navigation

Each on-demand SLO result carries its exact canonical service identity and returned
absolute evaluation range. `/slos` builds the existing `/investigate` URL from those
returned values; it does not recompute a relative range or embed investigation panels.
Disabled definitions are not evaluated by the frontend and therefore expose no
fabricated investigation interval there.

SLO evaluation composes Metrics in the backend for the bounded reliability calculation,
but Service Investigation itself remains frontend composition over public Metrics,
Traces, and Logs contracts.

## Self-observability

Existing signal-specific backend instrumentation observes composed HTTP/query calls,
latency, failure outcome, result size, and provider probes. Platform telemetry remains
classified with `geordi.telemetry.origin=platform`. Raw query text, service identity,
trace IDs, response bodies, exception messages, and other high-cardinality attributes
remain excluded. No aggregator telemetry or frontend page-view endpoint is added.

## Replaceability and Logs composition

Composition consumes public vendor-neutral contracts, so VictoriaMetrics, Tempo, and
Loki remain replaceable behind their adapters. Logs consumes the same signal-neutral
context and fails independently; it adds no shared Java identity, generic query
abstraction, or cross-signal domain dependency.
