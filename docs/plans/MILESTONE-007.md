# Milestone 007 — Alerting & SLO Foundations

Status: READY FOR GITLAB REVALIDATION

## Objective

Deliver the smallest trustworthy SLO evaluation capability over Geordi's canonical
Metrics contracts. Operators can inspect deployment-managed objectives, evaluate their
current status, understand the value/target/window used, and navigate to the existing
Service Investigation context. This milestone is SLO evaluation, not a notification or
incident-management product.

## Product contract

SLO definitions are a read-only, deployment-managed YAML catalog. The initial APIs are
`GET /api/slos`, `GET /api/slos/{sloId}`, and
`GET /api/slos/{sloId}/evaluation`; there are no create, update, delete, or enable/
disable endpoints. The catalog stores canonical Geordi service identity, not provider
queries. An operator changes a definition through controlled deployment configuration,
then restarts/redeploys according to the selected configuration lifecycle.

Each definition has a stable id, name, nullable description, exact canonical
`(service.namespace|null, service.name, environment)` identity, SLI type, ratio target,
predefined window, and enabled state. Null namespace means exact absence and never a
wildcard. SLO target values are finite ratios in `[0,1]`, never ambiguous percentages.

Only two semantically supported SLIs are in scope:

- `AVAILABILITY`: `(N - E) / N`, met when observed value is `>= target`.
- `ERROR_RATE`: `E / N`, met when observed value is `<= target`.

`N` is the canonical whole-window total HTTP request count and `E` the canonical
whole-window 5xx error-request count. Evaluation uses one exact half-open interval
`[evaluatedAt - window, evaluatedAt)` for a predefined `PT5M`, `PT15M`, `PT1H`, or
`PT6H` window. Equality is met for either direction. The result returns the exact
range, evaluated timestamp, observed ratio, request count, status, and optional reason.

No latency SLI is included. Existing p95 metric series are rollup series; selecting a
latest point would not truthfully mean p95 across an SLO window.

## Status and no-data semantics

The closed evaluation status set is `MET`, `BREACHED`, and `UNAVAILABLE`.

- `MET` and `BREACHED` require valid finite whole-window counts and at least one
  request. A zero error count is valid when it is explicitly observed.
- `UNAVAILABLE` is not breached and is not met. It applies to disabled definitions,
  no traffic, missing request/error counts, invalid/non-finite telemetry, and Metrics
  unavailability. The result reason is respectively `DISABLED`, `NO_TRAFFIC`,
  `MISSING_REQUEST_COUNT`, `MISSING_ERROR_COUNT`, `INVALID_TELEMETRY`, or
  `METRICS_UNAVAILABLE`.
- No requests, missing numerator, missing denominator, provider failure, and malformed
  telemetry must never be converted to zero or a reliability conclusion.

Metrics/provider details remain behind canonical Metrics ports and adapters. PromQL,
VictoriaMetrics types, provider responses, arbitrary queries, and provider error text
must not enter SLO domain/application objects, the configured catalog, REST, or UI.

## Delivery plan

1. [x] Define the bounded product semantics and read-only OpenAPI contract before
   frontend work.
2. [x] Record the configuration-backed YAML-catalog decision and lifecycle in an ADR,
   including replacement path, deployment/reload limitations, validation, and why a
   mutable database-backed repository is out of scope.
3. [x] Add the SLO module through existing registration/activation conventions, with a
   canonical Metrics evaluation boundary and ArchUnit protections against provider and
   Metrics-infrastructure coupling.
4. [x] Implement YAML catalog loading/validation and vendor-neutral whole-window
   request/error observations test-first; expose the three read-only endpoints and
   canonical disabled/not-found behavior, with invalid catalogs rejected during startup.
5. [x] Add `/slos` list/detail evaluation UI. It must show textual accessible status,
   target, observed value, whole window, unavailable reason, and exact-context
   navigation to `/investigate`; it must have loading, empty, disabled, unavailable,
   and request-failure states without stale evidence.
6. [x] Add low-cardinality SLO self-observability and a semantic smoke using
   deterministic success/error traffic. Preserve the five existing smokes and invoke
   the SLO smoke from authoritative GitLab `local_stack_smoke` with unconditional log
   capture and Compose cleanup.
7. [x] Run backend tests, ArchUnit, PMD, SpotBugs, Find Security Bugs; frontend tests,
   typecheck, lint, build; Compose validation/startup; all existing and SLO smokes.
8. [x] Obtain independent read-only review, fix all BLOCKER/HIGH findings, rerun the
   relevant verification, and synchronize architecture/product/startup/API documents.

The complete backend/frontend quality gates, Compose startup, all six semantic smokes,
provider-failure exercise, and independent review passed locally. The review found no
BLOCKER or HIGH findings; all MEDIUM findings and the LOW test-coverage finding were
resolved and the affected gates rerun.

## Acceptance criteria

- The catalog exposes only validated read-only definitions with exact canonical service
  identity, supported SLI types, finite ratio targets, and predefined windows.
- Availability and error rate use correct whole-window counts; availability/error target
  direction and equality semantics are correct.
- No traffic, explicitly valid zero errors, missing numerator, missing denominator,
  malformed/non-finite values, Metrics unavailable, and disabled definitions remain
  distinguishable and never produce a misleading `MET` or `BREACHED` outcome.
- Evaluation response exposes target, observed value when valid, request count when
  valid, exact `[from,to)` window, evaluation timestamp, status, and reason without
  provider syntax or error details.
- `/slos` is accessible and status is never conveyed by color alone. A result links to
  Service Investigation with the returned exact service namespace/name/environment and
  range; stale identity/range/evaluation data are never displayed.
- The SLO module follows existing activation/health semantics and emits bounded
  platform telemetry without selected service identity, provider query text, or error
  text as metric attributes.
- Backend/frontend quality gates, Compose startup, existing semantic smokes, a focused
  SLO semantic smoke, and independent review have no unresolved BLOCKER/HIGH finding.

## Definition of Done and status rule

Local completion requires every acceptance criterion, synchronized documentation,
complete CI-equivalent quality/Compose/smoke verification, and independent review with
no unresolved BLOCKER/HIGH finding. After successful local verification the maximum
status is `READY FOR GITLAB REVALIDATION`.

Milestone 7 must not be marked `COMPLETE` unless the project owner explicitly confirms
that the authoritative GitLab CI pipeline is green. If mandatory verification fails,
status is `NOT READY`.

## Non-goals

No mutable SLO CRUD UI/API, local JSON repository, database, new telemetry storage,
notifications, email/Slack/Teams/SMS/webhooks, PagerDuty/Opsgenie, Alertmanager,
routing/escalations/on-call, incident management, acknowledgement, silences,
maintenance windows, generic PromQL or alert-rule engine, arbitrary expressions,
composite/anomaly/AI alerts, error budgets/burn rates, long-period/calendar compliance,
latency SLOs, arbitrary windows, multi-tenancy, new providers, or Milestone 8 scope.
