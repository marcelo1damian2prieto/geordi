# Milestone 013 — Alert Routing & Suppression Foundation

Status: IMPLEMENTATION IN PROGRESS

## Objective

Add deployment-managed, deterministic routing to the existing atomic M10/M11
handoff. A canonical lifecycle transition is routed exactly once before its
transaction commits. The result is `MATCHED(destination)`, `SUPPRESSED`, or
`UNROUTED`.

## Scope and boundaries

The existing `alerts` bounded context gains a provider-neutral routing port and
value model. A configuration adapter supplies bounded, ordered routes and webhook
destinations. M10 remains the lifecycle owner and M11 remains the durable outbox and
delivery owner. A matching transition creates one persisted M11 delivery binding;
suppressed and unrouted transitions commit lifecycle state without delivery work.

Routing configuration failures fail before commit. Routing is neither evaluated by
M9/M12 nor recomputed by the M11 worker. The worker dispatches only against the
persisted destination identity and fingerprint; a removed or incompatible destination
is a terminal delivery failure with no fallback.

Routes use only optional exact policy, namespace, service, environment and transition
predicates. The first declared match is terminal. `DELIVER` requires a known
destination and `SUPPRESS` forbids one. No match is explicitly `UNROUTED`.

## Execution plan

1. Add ADR-018 and this plan before product edits.
2. Replace the one-destination selection port with a routing decision port, domain
   outcomes, bounded configuration validation, and focused unit tests.
3. At the existing M10 CAS/outbox transaction seam, derive the transition, route it,
   and persist one delivery only for a match. Instrument bounded routing outcomes.
4. Replace the single webhook runtime configuration with a bounded destination map;
   dispatch by persisted binding without routing. Update Compose and deployment docs.
5. Add an isolated M13 smoke with independent local receivers, then run M9–M12
   regressions, backend quality gates, configuration validation, diff checks and an
   independent review.

## Non-goals

No silences, route reload or CRUD, fan-out, incident management, episode affinity,
additional channels, generic predicates, scheduling changes, or UI are included.

## Acceptance evidence

Tests prove exact and wildcard matching, ordered precedence, validation, suppression,
unrouted commits, atomic matched commits, CAS retry safety, immutable worker binding,
restart/retry stability, independent STARTED/RESOLVED routing, bounded telemetry and
secret non-disclosure. The isolated smoke uses two receivers and checks those outcomes
without depending on prior milestone fixtures.
