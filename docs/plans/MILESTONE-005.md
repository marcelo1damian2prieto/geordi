# Milestone 005 — Logs Vertical Slice

Status: COMPLETE

## Objective

Deliver the smallest useful Logs vertical slice: deterministic monitored-workload OTel
logs flow through the Collector to Loki, then through a vendor-neutral query port and
REST API to `/logs`. Extend the existing frontend Service Investigation with an
independently failing Logs section and let Trace Detail open related Logs only with a
valid carried canonical context.

## Product contract

Operators can discover complete monitored service identity tuples and search one exact
namespace (optional but exact), service, environment, and absolute `[from,to)` range.
The range is at most six hours; results are deterministic newest-first; default limit
is 100 and maximum is 200. Operators may filter by canonical OTel severity, a literal
substring of at most 256 characters, trace ID, and optional span ID (which requires a
trace ID). No LogQL, regex, boolean language, cursor, saved search, or arbitrary
attribute filter is accepted.

The UI distinguishes loading, no records, no matching ERROR records, disabled
capability, invalid context, and provider unavailable/malformed/timeout outcomes.
Service Investigation composes Logs with Metrics and Traces in the frontend; each
signal remains visible when another fails. Trace-to-Logs preserves only validated
canonical context and trace/span IDs, never provider syntax.

## Architecture decisions

- Loki 3.7.2 is the single initial backend; Collector-to-Loki uses native OTLP Logs.
- Loki uses TSDB v13 and exactly four labels with defaults ignored: `service.name`,
  `service.namespace`, `deployment.environment.name`, and
  `geordi.telemetry.origin`.
- All other data, including trace/span/request IDs, URLs, body, exception text, and
  arbitrary attributes, remains structured metadata/log fields.
- `LogsQueryPort` and public contracts are vendor-neutral; Loki/LogQL exist only in
  the outbound adapter. Logs, Metrics, and Traces domains stay separate.
- Canonical records expose timestamp, observed timestamp when available, severity,
  severity text, body, exact identity, trace/span IDs, and flat string attributes.

See ADR-012, ADR-013, and `docs/architecture/LOGS.md`.

## Delivery and local verification

1. [x] Define OpenAPI contracts before frontend implementation.
2. [x] Add Logs module/domain/application/adapter and ArchUnit rules test-first.
3. [x] Add pinned Loki, Collector export, health checks, persistence, and configuration
   validation without regressing Metrics or Traces routes.
4. [x] Extend the demo with deterministic INFO, WARN, and ERROR logs, including at least
   one trace-correlated record.
5. [x] Add `/logs`, Trace-to-Logs, and Service Investigation Logs UX with loading,
   empty, provider-failure, and stale-context tests.
6. [x] Add semantic Logs smoke proving ingestion, exact identity/range/severity/body,
   correlation, proxy/route behavior, and absence of high-cardinality Loki labels.
7. [x] Run local backend/frontend/static-analysis/Compose/smoke regressions.
8. [x] Complete independent review with no remaining BLOCKER or HIGH finding, then
   obtain project-owner confirmation that the authoritative GitLab pipeline is green.

## Acceptance criteria

- Real OTLP INFO, WARN, and ERROR records persist in Loki with exact monitored service
  identity, environment, body, severity, timestamps, and available trace/span IDs.
- Logs APIs discover exact identity tuples and search only the valid bounded canonical
  criteria; response field `logs` contains vendor-neutral records.
- Missing namespace never widens a query; empty logs and empty ERROR subsets are not
  provider failures.
- High-cardinality IDs, URLs, and request IDs are demonstrably absent from Loki labels
  but correlation fields remain usable as structured metadata.
- Logs module activation, disabled routes, real health, API errors (400/502/503/504),
  and isolation are covered.
- `/logs`, Trace-to-Logs, and Investigation-to-Logs preserve context and prevent stale
  evidence; Logs failure leaves Metrics/Traces visible.
- Backend tests, integration tests, ArchUnit, PMD, SpotBugs, Find Security Bugs,
  frontend tests with zero unhandled errors, typecheck, lint, build, Compose/Loki/
  Collector validation, existing semantic smokes, and Logs semantic smoke pass.
- Documentation matches implementation; no Milestone 6 scope is introduced; an
  independent review has no unresolved BLOCKER/HIGH finding.

## Non-goals

No Kubernetes/file/syslog/Windows Event Log collection, Fluent Bit management, arbitrary
pipeline processing, Grok, LogQL UI, generic query language, saved searches, dashboards,
log-based metrics, alerts, retention/archive/replay features, multi-tenancy, multiple
providers, full APM, service map, AI/RCA, or Milestone 6 work.

## Definition of Done and completion evidence

Local acceptance criteria and mandatory verification passed. Independent review was
completed, with no remaining BLOCKER or HIGH finding preventing validation. The
authoritative GitLab integration gate includes the Logs semantic smoke alongside the
existing self-observability, Metrics, and Traces verification, and the project owner
subsequently confirmed that authoritative pipeline green.

Milestone 5 therefore satisfies its Definition of Done and is `COMPLETE`. This status
does not remove the bounded product scope, known limitations, or non-blocking technical
debt documented here and in `docs/TECHNICAL_DEBT.md`.
