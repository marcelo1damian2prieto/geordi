# Milestone 009 — Alert Evaluation Foundation

Status: COMPLETE

## Objective

Deliver the smallest trustworthy, on-demand alert-condition evaluation over Geordi's
canonical current-window burn-rate evidence. An operator can inspect a deployment-managed
policy, understand the exact evidence and inclusive comparison used, and navigate to the
matching Service Investigation context.

This milestone evaluates conditions. It does not deliver notifications, create incidents,
or persist alert lifecycle state.

## Reconciled product and architecture contract

Alert Evaluation is a dedicated logical bounded context in the modular monolith. It owns
immutable alert-policy, threshold-comparison, disabled-policy, and stateless-result
semantics. It consumes M8's canonical SLO/burn evaluation through an alerts-owned port and
an SLO composition adapter. Alert domain/application code neither imports SLO types nor
queries Metrics or VictoriaMetrics, and it never recalculates request ratios or burn rate.

Policies are a version-controlled, read-only YAML catalog bounded to 50 entries and
validated atomically at startup. Each policy has a stable id, name, optional description,
enabled flag, referenced SLO id, and exactly one condition:

- `BURN_RATE_ABOVE`, defined inclusively as canonical `burnRate >= threshold`.

Thresholds are non-negative, finite, and safely representable by the public JavaScript
number contract. Zero is valid but operationally aggressive. Duplicate policy ids,
unknown SLO references, unsupported condition types, invalid values, unknown fields, and
catalog overflow fail startup. There is no runtime CRUD, dynamic reload, or database.

Evaluation statuses are exactly `CONDITION_MET`, `CONDITION_NOT_MET`, and `UNAVAILABLE`.
An available canonical burn value is compared as its M8 `BigDecimal`, never as a rounded
UI string. Valid burn zero remains evidence and is not met for a positive threshold. Any
M8 burn unavailability propagates to alert `UNAVAILABLE` with the same bounded reason,
including no traffic, missing/invalid telemetry, Metrics failure, disabled SLO, and zero
allowed bad ratio. A disabled alert policy returns `UNAVAILABLE/DISABLED` without calling
the SLO evaluator and without fabricating an evidence snapshot.

One alert evaluation preserves the SLO snapshot's exact service name, exact nullable
namespace, environment, configured window, `[from,to)` range, and `evaluatedAt`. It does
not call another clock. The API is read-only:

- `GET /api/alert-policies`;
- `GET /api/alert-policies/{policyId}/evaluation`.

The frontend uses a dedicated `/alert-evaluations` operational view. It shows explicit
textual condition status, policy/SLO identity, threshold, observed burn when available,
exact evidence window, bounded unavailable reason, and exact-context Investigation
navigation. It explicitly states that no notification or incident is created.

## Execution plan

1. [x] Confirm the clean M1–M8-complete baseline and inspect M8 evidence, identity,
   availability, exact-window, UI, smoke, and CI contracts.
2. [x] Reconcile architecture, product/docs, observability, backend, frontend, and DevOps
   read-only analyses.
3. [x] Define the OpenAPI contract and record the dedicated-boundary decision in ADR-017.
4. [x] Implement policy/catalog and pure comparison behavior test-first, including
   below/equal/above, valid zero, invalid thresholds, disabled policy, and references.
5. [x] Implement the SLO composition adapter, read-only REST API, module activation,
   low-cardinality telemetry, and ArchUnit protections.
6. [x] Implement `/alert-evaluations` with accessible status, stale-data protection, and
   exact Service Investigation navigation.
7. [x] Add deterministic isolated policies and a PowerShell semantic smoke that uses an
   independent exact-window provider recomputation to catch comparator reversal.
8. [x] Append the M9 smoke after Burn Rate in authoritative GitLab CI without adding a
   second provider outage or increasing timeouts without measured evidence.
9. [x] Synchronize product, architecture, deployment, API, startup, and technical-debt
   documentation.
10. [x] Run the complete local CI equivalent, Compose/config validation, all regression
    smokes, the M9 smoke, cleanup verification, and `git diff --check`.
11. [x] Obtain independent read-only review, fix every BLOCKER/HIGH finding, and rerun
    affected verification.

## Local verification evidence

- Backend clean verify: 190 tests passed; ArchUnit, PMD, SpotBugs, and Find Security Bugs
  passed with no findings.
- Frontend: 120 tests, type checking, ESLint, and production build passed. The existing
  non-blocking Vite chunk-size warning remains documented technical debt.
- Compose, Collector, Tempo, and Loki configuration validation passed; all images built
  under the pinned container toolchains.
- The complete regression smoke chain passed in CI order: OpenTelemetry, Metrics,
  Traces, Logs, Service Map, SLOs, Burn Rate with its single provider outage/recovery,
  and Alert Evaluation.
- Alert Evaluation also passed alone on a fresh stack after generating its own isolated
  traffic, proving that its semantic oracle does not depend on the preceding M8 smoke.
- Independent review found no BLOCKER or HIGH issue. Three MEDIUM findings were fixed
  and re-reviewed: standalone smoke reproducibility, coherent unavailable domain states,
  and exact near-threshold numeric presentation. No BLOCKER, HIGH, or MEDIUM finding
  remains.
- Stack cleanup and `git diff --check` passed; the PowerShell LF-to-CRLF message is an
  informational working-tree warning only.

## Acceptance and semantic evidence

The 64 acceptance criteria in the Milestone 9 brief are authoritative. In particular,
the semantic smoke must independently obtain the configured threshold, independently
recompute canonical burn evidence from persisted Metrics for the response's exact
identity and half-open range, apply `burnRate >= threshold`, and compare that oracle with
the Alert Evaluation response. Unit/API tests protect exact positive-threshold equality;
runtime traffic protects independently verified below- and above-threshold behavior.

Alert telemetry is limited to closed condition type, result status, and optional bounded
reason. Policy/SLO ids and names, service identity, threshold, observed value, timestamps,
provider expressions, payloads, and exception text are never telemetry attributes.

## Authoritative GitLab revalidation

The authoritative GitLab pipeline passed the preceding Service Map, SLO, and Burn Rate
gates and then the M9 command:

```powershell
pwsh -File ./scripts/verify-alert-evaluation.ps1 -TimeoutSeconds 150
```

Its semantic result was:

> PASS: Alert policy catalog, self-contained traffic generation, independent exact-window
> zero/not-met and elevated/met comparator evidence, disabled/no-traffic/zero-budget
> semantics, identity/range/threshold preservation, provider-neutral API, frontend
> Investigation context, and bounded self-observability verified.

The preceding Burn Rate gate already validates the relevant VictoriaMetrics outage and
recovery behavior. M9 intentionally composes that proven capability and does not repeat
the expensive provider-outage scenario in its own smoke.

## Explicit non-goals

No notification delivery or provider, routing, retry queue, templates, on-call or
escalation policy, acknowledgement, silencing, maintenance window, incident creation or
lifecycle, persistent alert instance/history, scheduler/background evaluation, generic
rule engine or expression language, arbitrary PromQL/MetricsQL/TraceQL/LogQL, composite
signal, anomaly/AI/RCA behavior, automatic remediation, topology inhibition, multi-window
burn paging, new telemetry storage, or Milestone 10 work.

## Closure

Milestone 9 is **COMPLETE**. Mandatory local verification and independent review passed
with no remaining BLOCKER or HIGH finding, and the project owner confirmed the
authoritative GitLab pipeline is green. The delivered scope remains the bounded,
provider-neutral, stateless Alert Evaluation foundation described above; none of the
explicit non-goals became part of M9.
