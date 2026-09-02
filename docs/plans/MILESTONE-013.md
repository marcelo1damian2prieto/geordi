# Milestone 013 — Alert Routing & Suppression Foundation

Status: COMPLETE

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

## Implemented scope

1. ADR-018 and this plan were added before product edits.
2. The one-destination selection port was replaced with a routing decision port, domain
   outcomes, bounded configuration validation, and focused unit tests.
3. At the existing M10 CAS/outbox transaction seam, the transition is derived, routed,
   and persists one delivery only for a match. Bounded routing outcomes are instrumented.
4. The single webhook runtime configuration was replaced with a bounded destination map;
   dispatch uses the persisted binding without routing. Compose and deployment
   documentation were updated.
5. An isolated M13 smoke with independent local receivers was added, followed by M9–M12
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

## Authoritative GitLab revalidation

Milestone 13 is complete after the authoritative GitLab pipeline passed backend
verification, deployment configuration, frontend verification, and `local_stack_smoke`.
The integration chain included the M9–M12 regressions; M12 verified automatic
M9/M10/M11 alert scheduling and restart recovery. The M13 isolated routing smoke passed
route A/B isolation, explicit `SUPPRESS` and `UNROUTED` outcomes, the durable no-delivery
boundary, persisted destination binding across retry/restart, notification security
isolation, and bounded routing telemetry. No known BLOCKER or HIGH issue prevents
closure.
