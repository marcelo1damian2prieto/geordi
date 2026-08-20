# Milestone 006 — Service Map / Dependency Discovery

Status: COMPLETE

## Objective

Deliver the smallest useful operational Service Map: a bounded graph of observed
monitored service-to-service calls derived from existing distributed traces, exposed at
`GET /api/service-map` and `/service-map`. It is derived evidence, not a new source of
truth or telemetry store.

## Product contract

One map uses one exact `deployment.environment.name` and a valid explicit-offset,
half-open `[from,to)` range no wider than six hours. A node is the exact canonical
identity `(service.namespace|null, service.name, environment)`. Namespace absence is
exact absence and never wildcard behavior.

An edge `caller -> callee` exists only for a direct monitored `CLIENT` parent and
`SERVER` child in the same available trace, with distinct full identities and a SERVER
start timestamp inside the selected range. A trace containing two services alone is not
evidence. Same-service edges are omitted. The initial scope does not infer async,
remote-parent-only, or span-link relationships.

Edges deduplicate by ordered full caller/callee identity. `evidenceCount` counts
distinct qualifying trace IDs; at most three deterministic trace references are
returned. The API contains only context, endpoint nodes, directed edges, bounded
evidence, and explicit `truncated`; it exposes no provider syntax or payload.

The graph is bounded to 50 candidate traces plus one truncation detector, eight
concurrent detail retrievals, a 10-second budget, 50 nodes, 100 edges, and three
evidence references per edge. Candidate, node, or edge caps set `truncated=true`.
Representative-evidence capping is explicit when `evidenceCount` exceeds the returned
evidence-list length and does not by itself imply that the graph is truncated.

The map means dependencies observed in available trace telemetry in the selected range.
Instrumentation, sampling, retention, incomplete data, and bounds can omit evidence;
an absent edge does not prove an absent dependency.

## Delivery plan

1. [x] Define vendor-neutral OpenAPI, product semantics, bounds, and failure contract.
2. [x] Add a Service Map module with a vendor-neutral trace-evidence boundary and
   ArchUnit protections against Tempo, Logs, Metrics, and provider-syntax coupling.
3. [x] Implement bounded derivation, exact identity/environment filtering, directed
   deduplication, distinct-trace evidence counting, and truncation behavior test-first.
4. [x] Implement `/api/service-map`, canonical errors (400/404/502/503/504), and
   low-cardinality self-observability without a duplicate trace-provider health probe.
5. [x] Add `/service-map` with bookmarkable environment/range state; distinguish loading,
   empty, invalid, unavailable, malformed, timeout, and truncated outcomes; preserve
   node-to-Investigation and edge-to-Traces context.
6. [x] Add the smallest deterministic downstream monitored demo workload and a Service
   Map semantic smoke; preserve all existing telemetry smokes. The authoritative GitLab
   `local_stack_smoke` job invokes it after self-observability, Metrics, Traces, and Logs
   with a bounded 180-second timeout and retains unconditional Compose log capture and
   cleanup. Its 20-minute job timeout reserves 18 minutes for the main script and two
   minutes for `after_script`, so a main-script timeout still reaches cleanup.
7. [x] Run local CI-equivalent verification and synchronize implementation documentation:
   Java 21 backend Docker verification passed 128 tests plus PMD, SpotBugs, and Find
   Security Bugs; frontend verification passed 87 tests, typecheck, lint, and build;
   full Compose build and the self-observability, Metrics, Traces, Logs, and Service Map
   semantic smokes passed.
8. [x] Obtain independent read-only review and resolve every BLOCKER/HIGH finding;
   final review reported none, documented the module-health interpretation, and the
   generated-artifact hygiene note was resolved.

## Acceptance criteria

- Real trace evidence derives exact directed caller-to-callee service edges; no new
  telemetry storage, provider syntax leakage, Metrics/Logs coupling, or generic graph
  engine is introduced.
- Identity and time semantics are exact: namespace isolation, environment isolation,
  server-start `[from,to)` inclusion, six-hour maximum, and no namespace wildcard.
- Multiple qualifying spans from the same trace count once per edge; multiple distinct
  trace IDs deduplicate into one edge with the correct count and bounded evidence.
- Same-service, co-occurrence-only, platform, unclassified, incomplete-identity, and
  unsupported async evidence create no edge.
- Empty data, invalid query, disabled capability, malformed/unavailable/timeout provider
  outcomes, and explicitly truncated success are distinguishable. The UI never claims
  complete architecture.
- Nodes are readable and navigate to existing Investigation; directed edge evidence
  navigates to existing Traces with validated canonical context and no stale data.
- Backend tests, integration tests, ArchUnit, PMD, SpotBugs, Find Security Bugs,
  frontend tests with zero unhandled errors, typecheck, lint, build, Compose validation,
  existing smokes, and Service Map semantic smoke pass.

## Definition of Done and completion evidence

Local CI-equivalent verification and documentation synchronization passed. Independent
review completed with 0 remaining BLOCKER findings and 0 remaining HIGH findings. The
authoritative GitLab integration gate includes the Service Map semantic smoke after the
existing self-observability, Metrics, Traces, and Logs verification, and the project
owner confirmed that updated authoritative pipeline green.

Milestone 6 therefore satisfies its Definition of Done and is `COMPLETE`. This status
does not make the observed graph authoritative or complete and does not remove any
sampling, instrumentation, retention, bounded-query, truncation, or scope limitation
documented below or in `docs/architecture/SERVICE_MAP.md`.

## Non-goals

No topology persistence/cache/graph database, static or configured topology, CMDB,
topology editor, infrastructure/Kubernetes/host/process/database/broker/external-SaaS
nodes, Logs- or Metrics-derived discovery, edge RED analytics, alerts/SLOs, critical
path analysis, deployment/version overlays, eBPF, packet inspection, service mesh,
multi-tenancy, extra providers, AI/RCA, generic topology engine, or Milestone 7 scope.
