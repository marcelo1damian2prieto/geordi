# ADR-018: Deterministic Alert Routing and Suppression Boundary

Status: ACCEPTED

## Context

M10 derives canonical lifecycle transitions and M11 atomically persists durable webhook
delivery work. M13 needs deployment-managed routing while retaining this one winning
transition boundary and preventing later configuration changes from altering work that
is already durable.

## Decision

Place routing at option B: after M10 has derived the canonical transition and before
the atomic lifecycle/outbox commit. A route evaluation produces exactly one terminal
outcome: `MATCHED(destination)`, `SUPPRESSED`, or `UNROUTED`. Routing configuration or
execution errors fail the operation and prevent the lifecycle commit.

Routes are ordered and use first-match semantics. Exact optional predicates are policy
id, service namespace, service name, environment, and transition type. Omitted fields
are wildcards. A `DELIVER` route requires one configured destination; `SUPPRESS` is
explicit and cannot contain a destination. No matching route is `UNROUTED`; lifecycle
state commits but no outbox row is created. Operators may add a final catch-all delivery
route when desired.

For `MATCHED`, M11 persists the selected non-secret destination identity and fingerprint
inside its current atomic transaction. M11 workers must never rerun routing and may only
resolve the persisted binding. A missing or incompatible configured destination is a
terminal delivery failure without fallback or rerouting. Delivery identifiers remain
based solely on the canonical transition.

`ALERT_STARTED` and `ALERT_RESOLVED` are independently routed against configuration
current at their respective commits. Existing delivery work is immutable. M10 has no
durable episode-level destination affinity; that behavior is deferred with episode
modeling. One transition selects at most one destination: fan-out is out of scope.

## Consequences

Configuration and HTTP mechanics remain outbound adapters; the routing model and port
remain Spring- and vendor-independent. Metrics record bounded evaluation outcomes only,
with an allowlisted transition label and no identities, routes, endpoints, or secrets.
Deployment configuration is startup-validated for bounded sizes, IDs, predicates,
duplicate predicates, action/destination consistency, security settings and known
references where available.

Silences, enable/disable-as-suppression, runtime mutation/reload, generic expressions,
new notification channels, incidents and fan-out remain deferred.
