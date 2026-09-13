# Milestone 018 — Bounded Multiwindow Multi-Burn-Rate Alert Evaluation

Status: M18 PLANNED — READY FOR IMPLEMENTATION

## Purpose and operator outcome

M18 lets an operator define a bounded, standards-aligned multiwindow burn-rate alert
without changing the configured SLO window or losing the durable evidence behind an
alert episode. A policy may retain the legacy scalar `BURN_RATE_ABOVE` condition or use
`MULTIWINDOW_BURN_RATE` with one or both supported bands:

- `PT1H` plus `PT5M`;
- `PT6H` plus `PT30M`.

Each band is met only when both its long- and short-window burn rates are at least its
single canonical threshold. The condition is met when any band is met. Unknown evidence
uses strong three-valued logic, so an unavailable observation does not erase a decisive
false band or a decisive true condition. Every requested observation is nevertheless
collected and durably represented.

Operator story:

> I can alert on sustained and recent error-budget consumption, inspect every bounded
> observation that produced the result, and upgrade existing firing alerts without
> changing their meaning or losing their ability to recover.

This is an implementation plan. It does not implement M18 or mark it complete.

## Authoritative baseline and planning boundary

This plan was prepared from a clean `main` worktree at
`83cb7232a7d91fbaa7014b831890a3584f012f56` (`docs(alerts): reconcile milestone 17
closure`). `git status --short --branch` reported `## main...origin/main`; no tracked or
untracked changes existed before this file was created. That exact SHA is the
authoritative planning baseline.

At planning closure, `docs/plans/MILESTONE-018.md` is the only permitted changed file.
No production code, test, OpenAPI, frontend, deployment, CI, migration, existing ADR,
or architecture-document change belongs to this planning task. Implementation must
recheck `main`, `origin/main`, the diff since this baseline, and all named files before
starting; if repository changes contradict a settled invariant here, stop and reconcile
the concrete contradiction rather than silently changing product scope.

M1–M17 are implemented and their milestone status documentation is reconciled.
M18 implementation must not reopen M17 status or semantics unless repository
inspection reveals a concrete contradiction requiring correction. M18 implementation
must reconcile those status lines as documentation maintenance without treating them as
an M18 product decision.

## Current repository constraints

Repository inspection establishes the following starting facts:

- `io.geordi.slos.domain.EvaluationWindow` and
  `io.geordi.alerts.domain.EvaluationWindow` are distinct enums and currently contain
  only `PT5M`, `PT15M`, `PT1H`, and `PT6H`. The Alerts enum is already used as configured
  SLO-window provenance in lifecycle bindings, so widening it would still permit an
  invalid provenance value even though it would not widen SLO YAML parsing.
- `ConfigurationSloDefinitionCatalog` parses public SLO YAML with
  `io.geordi.slos.domain.EvaluationWindow.from(...)`; changing that enum would change
  the M7 public configuration contract.
- `AlertCondition` is currently one scalar record, `AlertEvaluation` assumes scalar
  available evidence for every decisive result, and `BurnRateEvidencePort` requests
  only the configured SLO evaluation.
- `SlosReliabilityAdapter` translates SLO values into Alerts values. Alerts must not
  become an upstream dependency of the SLO module.
- `SloEvaluationService` captures one clock instant and evaluates the configured SLO
  window through `RequestOutcomeMeasurementPort`. Its SLI, low-traffic, and burn-rate
  rules are the canonical M7/M8 semantics to reuse.
- `H2AlertLifecycleRepository` currently uses default Jackson domain serialization for
  lifecycle, transition-history JSON, and outbox transition JSON. Those are durable
  compatibility boundaries, not implementation details that may evolve implicitly.
- M10 lifecycle state, M11 outbox delivery, M14 transition history, M16 acknowledgement,
  and M17 notification disposition/correlation remain separate authorities.
- The frontend uses handwritten TypeScript contracts; there is no generated OpenAPI
  client. Existing evidence renderers live in Alert Evaluation, lifecycle, and episode
  detail views, and Investigation links require an exact absolute half-open range no
  longer than six hours.
- GitLab has `backend`, `frontend`, `deployment_configuration`, and exclusive Windows
  `local_stack_smoke` jobs. The latter already has a 30-minute job timeout and 27-minute
  script budget and runs the ordered semantic regression chain.

## Final authority and dependency boundaries

The following boundaries are final for M18:

1. The configured SLO definition remains authoritative for SLO ID, canonical service
   identity, SLI type, target, enabled state, and exactly one configured provenance
   window.
2. The public/configured SLO window contract remains exactly `PT5M`, `PT15M`, `PT1H`,
   and `PT6H`. `PT30M` must not be added to
   `io.geordi.slos.domain.EvaluationWindow`.
3. The Alerts domain owns alert observation windows and supported burn bands. Add a new
   closed `AlertObservationWindow` (name may be shortened if equally explicit) containing
   only `PT5M`, `PT30M`, `PT1H`, and `PT6H`. Keep the existing Alerts
   `EvaluationWindow` as the exact configured-SLO provenance mirror and do not add
   `PT30M` to it. This type split makes an invalid configured `PT30M` unrepresentable
   while allowing it in evidence and bands.
4. The SLO application side owns a provider-neutral bounded windowed-burn capability.
   Its request representation uses durations or an SLO-internal closed value, never an
   Alerts type. It resolves the SLO once, captures one `evaluatedAt`, validates a bounded
   set of at most four windows, and returns one coherent result.
5. `SlosReliabilityAdapter` is the explicit translation boundary from Alerts observation
   windows to the SLO-internal request and from SLO results to Alerts evidence.
6. MetricsQL/PromQL, VictoriaMetrics response shapes, HTTP clients, and provider timeout
   details stay in outbound adapters. Domain and application types remain vendor-neutral.
7. M10 remains lifecycle-state authority; M14 remains transition-history and transition
   identity authority; M11 remains delivery-work authority; M17 remains notification
   disposition and full-transition correlation authority.
8. Evidence is durable fact. Current policy configuration is never consulted to decode
   a stored transition or select its webhook schema.
9. No SQL migration is justified solely by M18 because the affected durable columns
   already contain JSON. Compatibility is provided by an explicit adapter-owned codec.
10. The modular monolith, single-node scheduler authority, fixed cadence, bounded workers
    and queue, overlap prevention, and no missed-tick replay remain unchanged.

Add or extend ArchUnit only where it can enforce a real rule: SLO production packages
must not depend on Alerts, domain/application packages must not depend on provider or
Jackson persistence DTO packages, and provider query syntax must remain adapter-local.

## Domain model and canonical semantics

Replace the open scalar shape with a closed condition hierarchy:

```text
sealed interface AlertCondition
  permits BurnRateAboveCondition, MultiwindowBurnRateCondition

BurnRateAboveCondition
  threshold

MultiwindowBurnRateCondition
  canonical immutable list<BurnRateBand> (size 1..2)

BurnRateBand
  longWindow
  shortWindow
  threshold
```

`AlertConditionType` retains `BURN_RATE_ABOVE` and adds
`MULTIWINDOW_BURN_RATE`. Do not use a record with nullable scalar and bands fields.
Constructors/factories must:

- require finite, non-negative, publicly representable thresholds;
- normalize thresholds with `stripTrailingZeros`, so `6`, `6.0`, and `6.00` are equal;
- accept only `(PT1H, PT5M)` and `(PT6H, PT30M)`;
- reject duplicate window pairs even when thresholds differ;
- treat band input order as semantically irrelevant and sort with explicit stable ranks,
  independent of enum declaration order: `(PT1H, PT5M)` rank 0 and `(PT6H, PT30M)` rank
  1; observations use `PT5M` rank 0, `PT30M` rank 1, `PT1H` rank 2, and `PT6H` rank 3.
  Equality, persistence, API output, and webhook output use these ranks. Transition,
  episode, and delivery ID inputs remain unchanged and do not include condition/evidence;
- preserve legacy scalar equality and serialization meaning.

Use a closed band outcome, conceptually `MET`, `NOT_MET`, and `UNAVAILABLE`. For each
band, compare both values inclusively (`burnRate.compareTo(threshold) >= 0`) and apply:

| Long | Short | Band |
| --- | --- | --- |
| T | T | T |
| T | F | F |
| F | T | F |
| F | F | F |
| F | U | F |
| U | F | F |
| T | U | U |
| U | T | U |
| U | U | U |

Across canonical bands, any T means `CONDITION_MET`; all F means
`CONDITION_NOT_MET`; otherwise the result is `UNAVAILABLE` with aggregate reason
`MULTIWINDOW_EVIDENCE_UNAVAILABLE`. Evaluation must request and retain the full union
of windows before computing this result; logical short-circuiting may not suppress
evidence acquisition.

Keep `BurnRateEvidence` as the legacy scalar variant. Add a closed aggregate variant,
conceptually:

```text
MultiwindowBurnRateEvidence
  sloId
  ServiceIdentity service
  EvaluationWindow configuredSloWindow
  Instant evaluatedAt
  canonical List<WindowBurnRateObservation> observations (size 2..4)

WindowBurnRateObservation
  AlertObservationWindow observationWindow
  TimeRange range
  observedBurnRate XOR bounded AlertUnavailableReason

BurnRateBandResult
  canonical BurnRateBand band
  long observation reference/value
  short observation reference/value
  band outcome
```

Construct aggregate evidence only through a factory that requires both the canonical
requested `Set<AlertObservationWindow>` and the returned observations. The requested set
is validation input, not duplicated durable/public state: it must contain two through
four unique supported values. The factory must prove one SLO, one service, one common instant,
`range.to == evaluatedAt`, `range.from == evaluatedAt - observationWindow`, exactly one
value/reason, no missing/extra/duplicate requested windows, two through four
observations, and canonical order. Evaluation revalidates the evidence set against the
condition's canonical window union. The v2 decoder derives that union from the persisted
condition and passes it into the same factory, so malformed missing/extra evidence fails
closed. `configuredSloWindow` is provenance and is not one of
the requested alert windows unless the condition happens to request it. There is no
representative burn rate.

Refactor `AlertEvaluation` into explicit legacy and multiwindow variants, or an equally
closed composition, so these legal states are representable without weakening legacy
invariants:

- disabled policy: `UNAVAILABLE`, reason `DISABLED`, null evidence, no provider call;
- legacy decisive result: available scalar evidence;
- legacy unavailable result: matching unavailable scalar evidence;
- multiwindow decisive result: complete aggregate evidence, possibly containing an
  irrelevant unavailable observation;
- multiwindow unavailable result: complete aggregate evidence and aggregate reason
  `MULTIWINDOW_EVIDENCE_UNAVAILABLE`.

Band results must be canonical, validated against condition plus observations on
construction/decoding, and recomputable without telemetry or current configuration.

## Configuration compatibility

Keep this YAML valid and behaviorally unchanged:

```yaml
condition:
  type: BURN_RATE_ABOVE
  threshold: 1
```

Add only this closed alternative shape:

```yaml
condition:
  type: MULTIWINDOW_BURN_RATE
  bands:
    - long-window: PT1H
      short-window: PT5M
      threshold: 14.4
    - long-window: PT6H
      short-window: PT30M
      threshold: 6
```

`14.4` and `6` are examples, not defaults. Bind raw configuration into adapter-owned
DTOs, enforce strict unknown-field rejection, dispatch by exact type, then construct the
closed domain value. Reject absent/unknown type, scalar-plus-bands, threshold on the
multiwindow shape, bands on the legacy shape, empty or more-than-two bands, duplicate or
unsupported pairs, invalid thresholds, and unknown nested fields. Do not loosen global
Jackson settings to implement polymorphism.

Mandatory cross-boundary regression tests must prove `PT30M` is accepted in an Alerts
band/observation and rejected by SLO YAML through
`ConfigurationSloDefinitionCatalog`/`io.geordi.slos.domain.EvaluationWindow.from`.

## SLO-internal bounded provider capability

Introduce an SLO application input capability separate from the public M7/M8
`SloEvaluationUseCase`, conceptually:

```text
BoundedWindowedBurnRateUseCase.evaluate(sloId, BoundedObservationWindowRequest)

BoundedObservationWindowRequest
  canonical unique provider-neutral durations/windows (2..4; supported upper bound 4)

BoundedWindowedBurnRateResult
  definition identity/provenance
  common evaluatedAt
  one result per requested window
```

The implementation sequence is:

1. validate the bounded request before provider work;
2. resolve the SLO definition once;
3. capture the clock once;
4. derive exact ranges from that instant;
5. if the SLO is disabled, return a timed result with every requested observation
   unavailable and no provider call;
6. issue one bounded measurement operation governed by one overall deadline;
7. apply the existing `SliSemantics`, allowed-bad-ratio, and burn-rate rules independently
   per observation;
8. require exactly the requested result set and return it in canonical order.

Extract shared pure calculation only when needed to keep public M7/M8 evaluation and the
bounded path identical. Do not change public `SloEvaluation`, configured-window behavior,
or its endpoint. Per observation preserve:

- zero requests / `NO_TRAFFIC` is unavailable;
- missing request or error evidence is unavailable;
- negative, non-finite, error-greater-than-request, or otherwise invalid telemetry is
  unavailable;
- `ZERO_ALLOWED_BAD_RATIO` is unavailable;
- positive valid traffic with zero errors is available burn `0`;
- absent error-series normalization is allowed only when request evidence proves the
  window exists;
- a completely absent window is never converted to zero.

Extend the measurement output port with one bounded batch request/response rather than
calling the current scalar port in an unbounded serial loop. The architectural contract
does not require one HTTP request: VictoriaMetrics should combine queries efficiently,
preferably into one request if its exact pinned API makes that reliable; other adapters
may perform multiple calls only under one explicit overall deadline. Duplicate, unknown,
missing, or invalid provider results follow the exact table below. Serial work must not
multiply the current provider timeout by the number of windows.

Provider failure translation is exact:

| Provider result | Observation result |
| --- | --- |
| transport failure, deadline expiry, or unparseable top-level response | every requested window is unavailable with bounded `METRICS_UNAVAILABLE` |
| duplicate or unknown correlation key | reject the whole response as corrupt; every requested window is unavailable with bounded `METRICS_UNAVAILABLE`, and emit only a bounded integrity outcome |
| requested window absent from an otherwise correlated response | that requested window is unavailable with `MISSING_REQUEST_COUNT`; other valid windows remain usable |
| known window with missing request evidence | that window is unavailable with `MISSING_REQUEST_COUNT` |
| known window with proven request evidence but absent error series | apply the existing justified absent-error normalization and use error count zero |
| known window with missing error evidence where normalization is not justified | that window is unavailable with `MISSING_ERROR_COUNT` |
| known window with non-finite, negative, or errors-greater-than-requests evidence | that window is unavailable with `INVALID_TELEMETRY` |
| known window with zero requests | that window is unavailable with `NO_TRAFFIC` |

A provider-wide unavailable result therefore normally yields an unavailable condition and
freezes lifecycle. A partial window failure remains a local U and is combined with all
other observations through the specified truth tables; it may still produce a decisive
`CONDITION_MET` or `CONDITION_NOT_MET`. No adapter may silently drop corrupt keys or turn
an absent window into zero.

## Stateless alert evaluation and lifecycle

Dispatch in `AlertEvaluationService` by the closed condition variant. Legacy calls the
existing scalar port and preserves byte-for-byte public behavior. Multiwindow translates
the canonical Alerts window union through `SlosReliabilityAdapter`, receives the complete
aggregate, computes canonical band results, and applies the truth tables above.

M10 lifecycle transitions remain exactly:

| Evaluation status | Lifecycle action |
| --- | --- |
| `CONDITION_MET` | enter/remain `FIRING` |
| `CONDITION_NOT_MET` | enter/remain `INACTIVE` |
| `UNAVAILABLE` | freeze state |

Lifecycle binding continues to include policy ID, SLO ID, canonical condition,
`ServiceIdentity`, configured SLO window, and latest common evidence instant. It must
accept either closed condition variant while rejecting a semantic change from legacy to
multiwindow (or the reverse) under the same policy ID. The operational error remains an
immutable binding mismatch, not a new episode or implicit reset.

A firing multiwindow lifecycle retains the complete aggregate evidence and canonical
band results that caused the episode to fire. No constituent may be discarded. Stale
and duplicate checks use the aggregate common `evaluatedAt`; unavailable freeze,
transition-state rules, episode creation/resolution, routing, and acknowledgement remain
unchanged.

## Adapter-owned persistence codec and v1/v2 strategy

Before changing a domain type, capture frozen JSON fixtures produced by authoritative
M17 serialization for:

1. a never-fired/disabled or otherwise unbound legacy `INACTIVE` lifecycle;
2. a bound legacy `INACTIVE` lifecycle with its latest available evidence;
3. a legacy `FIRING` lifecycle with available latest and retained active evidence;
4. a legacy `FIRING` lifecycle whose latest evidence is unavailable while its older
   available active evidence remains retained;
5. legacy started and resolved `AlertTransition` payloads;
6. matching legacy M14 `transition_json` history values;
7. a legacy pending M11 outbox `payload_json` value.

Include fixed transition-ID, episode-ID, and delivery-ID vectors for those canonical
values. Fixtures belong under a focused
`backend/src/test/resources/io/geordi/alerts/adapter/out/persistence/compatibility/`
directory and must be generated/verified against the baseline before the condition
hierarchy changes. They are immutable after review.

Introduce a focused persistence component in the outbound adapter, for example
`AlertPersistenceJsonCodec`, with private explicit DTOs or neighboring package-private
DTO files. It owns all reads/writes for lifecycle aggregates and persisted transitions;
domain classes must not acquire Jackson polymorphism annotations.

Read contract:

- absent `persistenceFormatVersion` selects a frozen, explicit v1 decoder matching M17;
- version `2` selects the explicit v2 envelope/DTO decoder;
- null, unsupported, fractional, malformed, or unknown versions fail closed as a
  bounded persistence/integrity failure;
- v2 decoding reconstructs domain values and independently recomputes/validates band
  results from observations;
- reads never rewrite or backfill rows.

Write contract:

- legacy lifecycle and transition writes may remain in the exact v1 form to preserve
  stable payloads and webhook behavior;
- any multiwindow lifecycle uses
  `{"persistenceFormatVersion":2,"lifecycle":{...}}`;
- any multiwindow transition/history/outbox payload uses
  `{"persistenceFormatVersion":2,"transition":{...}}`;
- v2 field order, canonical list order, numeric rendering, null handling, time rendering,
  and enum spelling are deterministic and covered by exact round-trip/golden tests.

Route `H2AlertLifecycleRepository` lifecycle, M14 history, M11 outbox, M17 evidence
correlation, and delivery worker decode paths through this one codec. Keep relational
identity columns and all V1–V7 migrations unchanged. A failure after lifecycle/history/
outbox serialization still respects the existing atomic commit boundary.

M17 full-transition equality must compare decoded canonical domain values, not envelope
syntax. Preserve transition, episode, and delivery identity formulas: richer evidence
alone must not change IDs. Freeze vectors before codec/domain edits and rerun them after
every persistence slice.

## Existing legacy FIRING upgrade behavior

Compatibility is a hard acceptance gate. Starting M18 against an M17 database containing
a legacy firing lifecycle and pending legacy delivery must:

- decode all unversioned v1 values successfully;
- retain the legacy `BURN_RATE_ABOVE` binding and evaluate it only through scalar legacy
  semantics;
- freeze normally when legacy evidence is unavailable;
- resolve from genuine legacy `CONDITION_NOT_MET` evidence, producing the normal M10/M14
  resolution without rewriting the original lifecycle/history facts on read;
- continue/retry the pending delivery and emit the unchanged v1 webhook;
- preserve M17 full-transition equality correlation after v1 decoding.

Changing that policy to `MULTIWINDOW_BURN_RATE` under the same ID fails closed. The safe
conversion runbook is mandatory:

1. upgrade the binary;
2. retain the legacy policy unchanged;
3. verify persisted legacy state reads;
4. introduce the multiwindow policy under a new policy ID;
5. keep the legacy policy enabled until genuine recovery resolves any firing episode;
6. allow pending legacy deliveries to complete;
7. only then remove the old policy configuration.

## Webhook v1/v2 strategy

The sender selects schema only from the persisted decoded transition representation.
It must not inspect current policy configuration.

Legacy persisted transitions, including pending pre-upgrade deliveries, keep the exact
`geordi.notification.v1` structure, delivery identity, `Idempotency-Key`, routing
binding, retry policy, worker ownership, and terminal-state behavior.

Multiwindow persisted transitions emit `geordi.notification.v2` with only:

- `schemaVersion`, `deliveryId`, `transitionType`, and `occurredAt`;
- policy ID/name and SLO ID;
- canonical multiwindow condition;
- evaluation status and bounded aggregate reason;
- service and configured SLO window;
- common `evaluatedAt`;
- all canonical observations, with exact ranges and value or bounded reason;
- all canonical band results.

The v2 mapper must not expose destination/URL, fingerprint, credentials, token, headers,
provider query, raw telemetry, request/error counts, claim/lease state, response content,
or arbitrary exception text. Add exact golden v1 regression fixtures and deterministic
v2 payload tests, including retry/restart reuse of the same persisted representation.

## API and OpenAPI contract

Keep every legacy request and response wire-compatible. Model new values with explicit
OpenAPI 3.1 `oneOf` variants; do not rely on a discriminator whose property path is
nested, such as `condition.type`. A complete evaluation variant may constrain its nested
condition's `type` with `const`.

Define exact schemas for:

- legacy burn-rate condition;
- multiwindow condition and burn band;
- legacy scalar evidence;
- multiwindow aggregate evidence;
- window observation;
- band result and band outcome;
- aggregate unavailable reason;
- closed legacy and multiwindow evaluation/lifecycle/history variants.

Keep existing paths, status codes, RFC 9457 sanitized error behavior, pagination,
filters, limits, and M14 transition-list identity. No provider query syntax or raw
telemetry enters OpenAPI. Add controller contract tests proving old fixtures still parse
and serialize exactly, new variants are closed, invalid mixed shapes fail, and forbidden
fields are absent.

## Frontend changes

Add no route and no policy editor. Extend only places that already display evaluation
evidence:

- `AlertEvaluationsPage` / its presentation helpers;
- `AlertLifecyclePage` / its presentation helpers;
- `AlertEpisodeDetail` and alert-history presentation where rich transition evidence is
  already shown.

Handwritten API types use discriminated unions for legacy versus multiwindow conditions,
evidence, evaluations, retained lifecycle evidence, and history transition details.
Render configured SLO window provenance, each canonical band, threshold, long and short
windows, every burn value or bounded unavailable reason, each band result, and aggregate
result. Do not invent severity, priority, incident, or paging language.

For every observation, construct an Investigation link only when service identity and
its exact persisted range pass the existing telemetry-context validator. Six-hour links
remain valid; invalid/absent evidence has no link. Preserve accessibility, semantic
labels, keyboard navigation, loading/error isolation, history deep links,
acknowledgement, notification status, cached-detail warning, and safe text rendering.

## Scheduler and deadline impact

Do not change the M12 scheduling model. Test that a policy evaluation owns one bounded
deadline encompassing all requested observations and cannot overlap the same policy.
Provider delay or timeout must return bounded unavailable evidence/result within that
deadline and release the single-flight slot. Preserve fixed cadence, worker/queue bounds,
no missed-tick replay, and single-node ownership.

Measure healthy and failure-path duration with one-band and two-band policies. Do not
multiply an existing per-request timeout fourfold. If the required bounded deadline does
not fit the current scheduling cadence or queue assumptions, stop for an explicit owner
decision instead of silently increasing concurrency or skipping windows.

## Semantic smoke plan

First run a disposable feasibility probe against the exact pinned VictoriaMetrics image
and current metric names/query translator. Prove that explicitly timestamped historical
samples covering six hours can be imported, queried at a fixed evaluation instant, and
kept isolated by a dedicated `ServiceIdentity`. Verify raw request/error series and
independently calculated ranges and rates before invoking Geordi. This probe is a
planning gate, not permanent product behavior. If historical import or timestamp control
is unreliable, stop and revise the smoke strategy; do not substitute timing-dependent
six-hour traffic generation. The current pin is `victoriametrics/victoria-metrics:v1.148.0`;
the feasibility step must re-read the Compose pin and stop if it changed.

Prefer extending `scripts/verify-alert-evaluation.ps1`. Add a deterministic multiwindow
policy/SLO fixture through the narrowest existing deployment configuration. Avoid a new
full-stack startup or overlay unless implementation evidence proves it unavoidable. The
fixture must produce, at the common returned `evaluatedAt`:

- `PT1H` burn at or above its threshold;
- `PT5M` burn below that same threshold, making band 1 `NOT_MET` by AND;
- `PT6H` burn at or above its threshold;
- `PT30M` burn at or above that same threshold, making band 2 `MET`;
- overall `CONDITION_MET` by OR.

Use a fixed counter-rate recipe, adapted only to the exact current metric names: seed a
constant positive request rate across at least `evaluatedAt - 6h - scrape/query margin`
through `evaluatedAt + margin`; seed zero/low errors for the oldest interval, elevated
errors from approximately `evaluatedAt - 55m` through `evaluatedAt - 10m`, and recovered
zero errors for the final ten minutes. Choose explicit numeric rates and per-band
thresholds only after raw-query feasibility, calculating them so the 1h long value clears
its threshold with margin while the recovered 5m value is strictly below, and both 6h
and 30m values clear their shared threshold with margin. Record the exact sample cadence,
timestamps, counter/rate values, query step/lookback semantics, calculations, and margins
in the script comments and implementation evidence; do not rely on equality at the
threshold. Import enough future margin to tolerate the bounded difference between the
fixture's nominal instant and Geordi's returned live `evaluatedAt`, then assert that the
returned instant lies inside that prevalidated margin. If the provider rejects future
samples or query-time semantics make that tolerance unreliable, stop and switch to a
documented controllable-clock test fixture rather than weakening assertions.

The script verifies raw imported samples/query results first, calls Geordi, derives each
exact range from the returned instant, calculates expected burn rates independently,
and asserts the complete canonical evidence union and band results. It then exercises
the applicable lifecycle/history/webhook-v2 path without duplicating exhaustive truth
tables or provider-failure permutations covered by backend tests. Preserve the ordered
M8-before-M9/M18 regression chain.

Record actual local stack-start, existing alert-evaluation smoke, extended M18 smoke,
and total chain durations. The existing GitLab job is 30 minutes with 27 minutes for the
main script and 3 minutes for cleanup. If measured integration time approaches that
budget, report CI partitioning/runtime as separate technical debt and request an explicit
timeout-budget decision; do not reduce semantic coverage. Any new Compose fixture must
use validated explicit volume/project names and guaranteed `finally`/`after_script`
cleanup, but the preferred implementation requires no new volume.

## Detailed implementation file map

Exact existing files and expected responsibility follow. New filenames are proposed
package-local names; implementation may combine a new small value with an adjacent file
only when the resulting boundary is clearer and the change is recorded in the plan.

### Alerts domain and application

- `backend/src/main/java/io/geordi/alerts/domain/AlertCondition.java` — convert to sealed
  interface; no nullable compatibility fields.
- new `BurnRateAboveCondition.java`, `MultiwindowBurnRateCondition.java`,
  `BurnRateBand.java`, and `BurnRateBandOutcome.java` — closed canonical condition model.
- `AlertConditionType.java` — add only `MULTIWINDOW_BURN_RATE`.
- `EvaluationWindow.java` — intentionally remains the four-value configured-SLO
  provenance mirror; add regression construction/codec tests that reject `PT30M`.
- new `AlertObservationWindow.java` — closed M18 observation values including `PT30M`;
  bands and observations use this type, never configured provenance.
- `BurnRateEvidence.java` — retain legacy scalar semantics.
- new `AlertEvidence.java` (closed common type if needed),
  `MultiwindowBurnRateEvidence.java`, `WindowBurnRateObservation.java`, and
  `BurnRateBandResult.java` — aggregate evidence and recomputable results.
- `AlertUnavailableReason.java` — add only the bounded aggregate reason and any precise
  leaf mapping genuinely needed; do not add arbitrary provider/error text.
- `AlertEvaluation.java`, `AlertPolicy.java`, `AlertLifecycle.java`,
  `AlertLifecycleTransitions.java`, and `AlertTransition.java` — closed variants,
  binding/retention invariants, unchanged transition state semantics and identity.
- `backend/src/main/java/io/geordi/alerts/application/port/out/BurnRateEvidencePort.java`
  — closed scalar/bounded request contract without provider types.
- `AlertEvaluationService.java` — variant dispatch, full collection, three-valued logic.
- `AlertLifecycleService.java`, `AlertLifecycleSnapshot.java`,
  `AlertLifecycleEvaluationResult.java`, and `SingleFlightAlertLifecycleEvaluationUseCase.java`
  — canonical binding, aggregate retention, stale/duplicate/deadline behavior.

### SLO and Metrics capability

- `backend/src/main/java/io/geordi/slos/domain/EvaluationWindow.java` and
  `backend/src/main/java/io/geordi/alerts/domain/EvaluationWindow.java` — intentionally
  no production widening; regression tests prove `PT30M` remains invalid configured
  provenance in both modules.
- `SloEvaluationService.java` and a new focused bounded use case/service under
  `io.geordi.slos.application` — resolve once, one clock instant, shared SLI/burn rules.
- new provider-neutral bounded request/result values under `io.geordi.slos.application`
  or `application.port.out`; do not import Alerts.
- `RequestOutcomeMeasurementPort.java`, `RequestOutcomeMeasurementRequest.java`, and
  `RequestOutcomeMeasurement.java` — retain scalar API and add a bounded batch seam or
  focused neighboring batch port.
- `MetricsRequestOutcomeMeasurementAdapter.java` — translate the SLO batch request to
  Metrics application values without VictoriaMetrics types.
- `backend/src/main/java/io/geordi/metrics/application/port/out/RequestOutcomeQueryPort.java`,
  `RequestOutcomeQueryService.java`, `RequestOutcomeQuery.java`, and
  `RequestOutcomeMeasurement.java` — bounded query/result contract and one deadline.
- `VictoriaMetricsAdapter.java`, `VictoriaMetricsQueryTranslator.java`,
  `VictoriaMetricsResponseParser.java`, and `VictoriaMetricsProperties.java` — efficient
  batch, exact result correlation, timeout/deadline; query syntax remains here.
- `SlosReliabilityAdapter.java` — explicit Alerts-window to SLO-request translation and
  aggregate evidence mapping while preserving the scalar path.
- `SlosModuleConfiguration.java`, `MetricsModuleConfiguration.java`, and
  `AlertsModuleConfiguration.java` — wire the new ports/decorators without cycles.

### Configuration, persistence, history, and delivery

- `AlertPoliciesProperties.java` and `ConfigurationAlertPolicyCatalog.java` — strict
  variant DTO parsing and canonical construction.
- `ConfigurationSloDefinitionCatalog.java` — no production widening; keep parser path.
- `H2AlertLifecycleRepository.java` — route all durable JSON through the codec; no SQL
  migration and no read-time rewrite.
- new `AlertPersistenceJsonCodec.java` plus explicit package-private v1/v2 persistence
  DTOs — frozen v1 decode, deterministic legacy/v2 writes, fail-closed versions.
- `AlertHistoryMutation.java`, `AlertTransitionRecord.java`,
  `AlertTransitionCommitIntent.java`, `NotificationDelivery.java`, and
  `AlertNotificationEvidence.java` — carry/compare decoded variants without ID drift.
- `AlertHistoryQueryService.java`, `AlertLifecycleQueryService.java`, and
  `AlertNotificationProjectionService.java` — expose truthful rich decoded evidence.
- `NotificationDeliveryWorkService.java` and `HttpWebhookNotificationSender.java` —
  persist/decode schema authority and v1/v2 payload selection; retry semantics unchanged.
- `AlertHistoryController.java`, `AlertLifecycleController.java`, and
  `AlertPolicyController.java` — explicit DTO variants and legacy wire compatibility.
- `ObservedAlertEvaluationUseCase.java`, `ObservedAlertLifecycleEvaluationUseCase.java`,
  `ObservedAlertHistoryRepository.java`, and delivery telemetry only where newly owned
  behavior needs observation — bounded labels only.

### Backend tests and fixtures

- `AlertsDomainTest.java` plus focused new condition/evidence tests — hierarchy,
  canonicalization, invariants, truth tables, equality.
- `ConfigurationAlertPolicyCatalogTest.java` — legacy/new YAML and strict rejection.
- `ConfigurationSloDefinitionCatalogTest.java` and `SloDomainTest.java` — frozen public
  SLO windows and explicit `PT30M` rejection.
- `SloEvaluationServiceTest.java` plus a bounded-service test — common instant, ranges,
  low-traffic semantics, max-four and result-set integrity.
- `MetricsRequestOutcomeMeasurementAdapterTest.java`,
  `VictoriaMetricsRequestOutcomeTest.java`, and `VictoriaMetricsMappingTest.java` —
  batch efficiency, partial/provider failure, correlation, timeout.
- `SlosReliabilityAdapterTest.java` and `AlertEvaluationServiceTest.java` — translation,
  disabled cases, all logical combinations, aggregate reason.
- `AlertLifecycleTransitionsTest.java`, `AlertLifecycleServiceTest.java`, and
  `SingleFlightAlertLifecycleEvaluationUseCaseTest.java` — lifecycle table, binding,
  retained aggregate, stale/duplicate and overlap.
- `H2AlertLifecycleRepositoryTest.java`, `H2AlertNotificationEvidenceTest.java`, and a
  new focused `AlertPersistenceJsonCodecTest.java` — v1 fixtures, restart/recovery, v2
  golden round trips, unknown/malformed versions, atomicity and M17 equality.
- frozen compatibility JSON under
  `backend/src/test/resources/io/geordi/alerts/adapter/out/persistence/compatibility/`.
- `NotificationDeliveryWorkServiceTest.java` and
  `HttpWebhookNotificationSenderTest.java` — pending v1 after upgrade, deterministic v2,
  retry/restart/privacy.
- controller tests for policy/evaluation/lifecycle/history — legacy byte compatibility,
  closed variants, sanitized failures and forbidden-field absence.
- `AlertEvaluationSchedulerTest.java` — cadence/queue/overlap and deadline interaction.
- `ArchitectureTest.java` — only enforceable dependency rules described above.

### Frontend, OpenAPI, smoke, and documentation

- `docs/api/openapi.yaml` — explicit 3.1 variants and schemas; preserve legacy shapes.
- `frontend/src/api/alertEvaluations.ts`, `alertLifecycles.ts`, and `alertHistory.ts` —
  handwritten discriminated unions; transport regressions.
- `alertEvaluationPresentation.ts`, `alertLifecyclePresentation.ts`, and
  `alertHistoryPresentation.ts` with their tests — canonical accessible rendering and
  exact links.
- `AlertEvaluationsPage.tsx`, `AlertLifecyclePage.tsx`, and `AlertEpisodeDetail.tsx`
  with page tests — evidence display only; no route/editor.
- `telemetryContext.ts` tests — preserve exact-range and six-hour constraints.
- `scripts/verify-alert-evaluation.ps1` — deterministic M18 extension after feasibility.
- existing policy/SLO fixture YAML and Compose only if needed for the smoke; prefer the
  current files and no new stack job.
- `.gitlab-ci.yml` only if measured runtime requires an approved timeout adjustment; do
  not partition CI or weaken coverage in M18.
- `docs/adr/ADR-021-bounded-multiwindow-burn-rate-conditions-and-durable-evidence-compatibility.md`.
- `README.md`, `docs/product/PRD.md`, `docs/product/ROADMAP.md`,
  `docs/architecture/SLOS.md`, `ALERT_EVALUATION.md`, `ALERT_LIFECYCLE.md`,
  `MODULES.md`, and `NOTIFICATION_DELIVERY.md`.
- `deploy/README.md` and relevant fixture documentation for rollout, persistence format,
  rollback, smoke, and policy replacement.

No migration file is expected. No file outside this map may be added merely for future
roadmap convenience.

## RED → GREEN implementation slices

Use small compile-coherent vertical slices. Every RED proves behavior or compatibility,
not a getter or framework binding.

1. **Freeze M17 before domain edits.** RED: fixture readers and fixed transition/episode/
   delivery ID vectors. GREEN: capture authoritative baseline JSON and make tests prove
   current decoding/equality. Stop if serialization cannot be deterministically frozen.
2. **Closed pure domain.** RED: sealed variants, threshold normalization, one/two bands,
   pair validation, duplicate rejection, canonical ordering, every AND/OR truth-table
   row, and aggregate evidence invariants. GREEN: minimal domain values and pure evaluator.
3. **Alerts-only `PT30M`.** RED: supported `PT6H/PT30M` observation band, rejection of
   `PT30M` as Alerts configured provenance, and SLO YAML rejection. GREEN: add the
   separate observation-window type and keep both configured-window enums/parsers
   unchanged.
4. **Strict configuration.** RED: unchanged legacy YAML, new one/two-band YAML, mixed and
   unknown fields, invalid thresholds/pairs/count/order. GREEN: adapter DTO dispatch and
   canonical construction.
5. **SLO bounded core.** RED: resolve once, one instant, exact ranges, full union,
   max-four, disabled SLO, zero/unavailable cases. GREEN: provider-neutral use case using
   shared SLI/burn semantics without changing M7/M8 public behavior.
6. **Provider batch and deadline.** RED: efficient bounded call(s), provider-wide failure,
   partial missing/invalid values, duplicates/unknowns, deadline. GREEN: Metrics and
   VictoriaMetrics adapters under one bounded deadline.
7. **M9 stateless evaluation.** RED: disabled-policy no-call, legacy unchanged, decisive
   result with irrelevant unknown, aggregate unavailable. GREEN: translate window union,
   collect all evidence, evaluate canonical bands.
8. **M10 lifecycle.** RED: start, resolve, unavailable freeze, stale, duplicate, binding
   mismatch, full aggregate retention, legacy firing recovery. GREEN: adapt binding and
   retained evidence without transition-state changes.
9. **Explicit codec.** RED: frozen v1 lifecycle/transition/history/outbox reads and v2
   deterministic golden round trips, unknown version, malformed/recomputed-result mismatch.
   GREEN: codec and repository integration; no migration or read rewrite.
10. **History and outbox decoding.** RED: v1/v2 history, pending v1 delivery, correlation,
    restart, atomic rollback. GREEN: route every JSON path through the codec.
11. **Webhook v2.** RED: legacy v1 structural golden, multiwindow v2 golden, schema chosen
    from persisted representation, privacy, retry identity. GREEN: closed sender mapping.
12. **M17 identity/correlation regression.** RED/GREEN: rerun fixed IDs and full decoded
    transition equality across v1/v2; do not redesign M17.
13. **Controllers and OpenAPI.** RED: old wire fixtures unchanged, new closed variants,
    invalid/mixed rejection and no leaks. GREEN: explicit DTO/oneOf mappings.
14. **Frontend evidence.** RED: transport unions, accessible values/reasons/results,
    exact Investigation links and regressions. GREEN: update existing renderers only.
15. **Semantic smoke.** Complete the pinned-VictoriaMetrics feasibility gate, then RED
    against the deterministic imported fixture and GREEN the existing script extension.
16. **ADR and documentation.** Record implemented reality, rollout, versioned persistence,
    rollback, API/UI, operational constraints, and reconcile stale M17 status prose.
17. **Local closure.** Run focused tests after each slice, then the complete gate below;
    record commands, counts, durations, and artifact provenance.
18. **Fresh independent implementation review.** Resolve all BLOCKER/HIGH; resolve or
    explicitly accept MEDIUM/LOW; rerun affected gates and inspect the final diff.

This order refines the proposed sequence only by making the cross-module `PT30M`
regression its own early gate and by requiring the persistence codec to precede every
history/outbox/webhook change. It preserves the dependency order and ensures irreversible
compatibility mistakes fail before broad API/UI work.

## Full verification matrix

### Domain and configuration

- closed condition hierarchy and exhaustive constructor invariants;
- threshold inclusive comparison and numeric equality (`6 == 6.0 == 6.00`);
- band order equality/canonical serialization;
- duplicate pairs rejected regardless of threshold;
- only the two supported pairs and one/two bands;
- every single-band AND and multi-band OR three-valued row;
- old YAML unchanged; valid new YAML; scalar/bands mixing and all unknown fields rejected;
- observation `PT30M` accepted; Alerts configured provenance and configured SLO YAML
  `PT30M` both rejected.

### Evidence, provider, and evaluation

- one exact `evaluatedAt`, exact ranges, one SLO/service/configured window;
- full requested window union, canonical order, no missing/extra/duplicate, max four;
- value XOR precise bounded reason; available zero; every low-traffic case;
- efficient bounded provider work, provider-wide and partial failure, invalid/unknown/
  duplicate result rejection, one overall deadline;
- disabled policy returns null evidence/no provider call;
- disabled SLO returns timed aggregate unavailable evidence/no provider call;
- decisive met/not-met with irrelevant unavailable constituent;
- no true plus at least one unknown gives aggregate unavailable reason.

### Persistence, lifecycle, delivery, and history

- all four frozen v1 fixture classes and exact reads;
- M17-era restart, legacy firing freeze/recovery, no read rewrite/backfill;
- deterministic v2 lifecycle/transition/history/outbox round trips;
- unknown version and malformed/derived-result mismatch fail closed;
- start, resolve, unavailable freeze, stale, duplicate, binding mismatch;
- multiwindow firing retains complete active aggregate;
- legacy pending delivery emits exact v1 after upgrade;
- multiwindow transition emits v2; retries/restart/identity unchanged;
- transition and episode fixed ID regression vectors;
- v1/v2 history reads and M17 full-transition equality correlation.

### API, frontend, scheduler, and regression

- legacy API/OpenAPI examples remain wire-compatible;
- new `oneOf` variants validate under OpenAPI 3.1 without nested discriminators;
- accessible evidence rendering in evaluation/lifecycle/history detail;
- exact valid Investigation link per observation and no invalid link;
- no new route/editor or forbidden data;
- scheduling duration/provider timeout, overlap, queue/cadence/no-replay invariants;
- focused M9 through M17 suites;
- full backend, frontend, Compose, OpenAPI, semantic smoke, and artifact-provenance gates.

## Local and authoritative closure gates

From repository root, implementation closure requires at least:

1. `git diff --check` and explicit changed-file inventory.
2. From `backend`, `.\mvnw.cmd -B -ntp verify` on Windows (or `./mvnw -B -ntp
   verify`), including JUnit, ArchUnit, PMD, SpotBugs, and Find Security Bugs.
3. Focused condition/evidence truth tables, SLO-window boundary, provider deadline,
   codec fixtures, legacy firing, webhook, identity/correlation, controller, scheduler,
   and telemetry tests with counts recorded.
4. From `frontend`, `npm ci`, `npm test`, `npm run typecheck`, `npm run lint`, and
   `npm run build`.
5. OpenAPI 3.1 validation, duplicate-key rejection, old-schema fixture comparison, and
   forbidden provider/internal-field search.
6. `docker compose config --quiet` for base and every maintained M10/M12/M13/M14 overlay
   combination used by CI, plus any narrowly approved M18 fixture.
7. Pinned-VictoriaMetrics historical-import feasibility record and raw query proof.
8. Extended `verify-alert-evaluation.ps1`, then the full ordered semantic regression
   chain; record each and total runtime.
9. Restart tests over frozen v1 and v2 durable state, plus rollback/read compatibility
   evidence.
10. Search public JSON, logs, traces, and metric labels for secrets, raw telemetry,
    provider syntax, exception text, and forbidden high-cardinality values.
11. Full diff and documentation/ADR synchronization review.
12. Fresh independent read-only implementation review with classified findings.

Local success does not complete M18. The project owner must provide authoritative GitLab
pipeline evidence for the exact candidate commit. Required jobs are `backend`,
`frontend`, `deployment_configuration`, and `local_stack_smoke`; the smoke must verify
the same-pipeline backend artifact revision and SHA-256 provenance before building the
runtime image and must pass the complete ordered chain including M18. Record pipeline
URL/ID, exact validated commit SHA, job results, backend test count, artifact digest,
semantic smoke results, runtime, reviewer counts, and accepted debt in this plan and the
product closure docs. Only then may status change to `COMPLETE`.

## Documentation and ADR implementation work

Create ADR-021 with the exact title **Bounded Multiwindow Burn-Rate Conditions and
Durable Evidence Compatibility**. It records the two EvaluationWindow authorities,
bounded SLO batch ownership, strong three-valued logic, canonical evidence, explicit
v1/v2 codec, identity preservation, webhook selection from persisted representation,
legacy firing rollout, and rollback boundary.

Synchronize:

- `README.md` — capability, configuration example, rollout/restart/rollback, smoke;
- `docs/product/PRD.md` and `ROADMAP.md` — M18 scope/status;
- `docs/architecture/SLOS.md` — configured window remains singular and bounded internal
  observation capability;
- `ALERT_EVALUATION.md` — condition/evidence variants and truth tables;
- `ALERT_LIFECYCLE.md` — binding, aggregate retention, legacy upgrade behavior;
- `MODULES.md` — SLO-owned port and Alerts adapter translation, no dependency reversal;
- `NOTIFICATION_DELIVERY.md` — persistence-driven webhook v1/v2 and retry invariants;
- `docs/api/openapi.yaml` — exact schemas;
- `deploy/README.md` — safe rollout, durable format/rollback, fixture and runtime notes.

Do not rewrite prior milestone plans or backfill old history. Architecture documents must
describe only behavior actually implemented when they are updated.

## Security, privacy, and self-observability

M18 adds no authentication/RBAC. Existing deployment trust boundaries remain. Validate
all configured and persisted closed variants at adapter boundaries, fail closed on
unknown persistence versions or inconsistent derived results, use parameterized
persistence/provider operations, and keep sanitized RFC 9457 failures.

Neither API, UI, webhook, logs, traces, metrics, nor errors may expose webhook destination,
URL, headers, credentials, tokens, provider query, raw telemetry/counts, claim/lease
data, response body, SQL/Jackson details, or arbitrary exception text.

Observe only work newly owned by M18, using bounded dimensions such as condition variant,
overall outcome, fixed supported band category, fixed observation-window value, and
bounded unavailable reason when justified. Never label with policy ID, SLO ID, service,
namespace, environment, threshold, arbitrary duration, provider query, destination,
transition/episode/delivery ID, exception class, or message. Prefer existing evaluation
and provider instruments; do not duplicate M8/M9/M10/M11 telemetry. Health remains
component availability, not row-by-row evidence validation.

## Rollback and rollout rules

Before the first durable v2 write, ordinary binary rollback to M17 remains possible,
provided no unrelated schema/configuration incompatibility exists. After the first v2
write, an M17 binary is not a supported reader even if all multiwindow policies are
disabled or removed.

Supported rollback after v2 requires either:

- a binary with an M18-compatible v2 reader; or
- coordinated restoration of pre-upgrade storage together with matching pre-upgrade
  policy configuration.

Storage restoration discards later lifecycle, history, acknowledgement, disposition,
and delivery facts and is operational data loss. Never present it as a transparent
rollback. Do not rewrite v2 rows to v1, delete them, or disable policies as an automatic
rollback mechanism. The deployment runbook must identify the first-v2-write boundary,
backup/restore validation, and the separate new-policy-ID rollout above.

## Explicit non-goals

M18 excludes `PT3D`, long-period compliance accounting, arbitrary window pairs, separate
long/short thresholds within a band, generic expressions/rule engines, minimum-request
thresholds, policy CRUD/reload/editor, severity, notification priority, ticketing,
escalation, paging, silences, maintenance windows, incidents, redrive/retry management
UI, new routes, multiple scheduler nodes, auth/RBAC, Spring Boot upgrade, SCA/SBOM, CI
partitioning, and ECharts optimization. It adds no SQL migration and performs no history
or persistence backfill.

Any newly discovered M17 documentation inconsistency is documentation maintenance,
not authority to redesign M17. General dependency vulnerability/SCA work and smoke-chain runtime pressure
remain separately tracked debt unless implementation finds an immediate concrete
security blocker.

## Risks and stopping conditions

- **Window-boundary leak:** if implementation requires adding `PT30M` to either configured-
  provenance `EvaluationWindow` enum, stop; introduce/repair the Alerts observation type
  and provider-neutral bounded request instead.
- **Implicit JSON polymorphism:** if a durable path still uses default domain
  serialization after the codec slice, stop before any v2 write.
- **Unfrozen legacy truth:** if authoritative M17 fixtures or ID vectors cannot be
  reproduced from the baseline, stop and resolve that evidence gap first.
- **Provider ambiguity:** if a batch response cannot correlate every result exactly, fail
  closed; do not assign by list position or synthesize zero.
- **Unbounded time:** if multiple calls cannot share one reliable overall deadline, stop
  and revise the port/adapter design.
- **Historical smoke instability:** if pinned VictoriaMetrics cannot reliably import and
  query fixed historical samples, stop and redesign the fixture rather than generating
  six hours of wall-clock traffic.
- **Legacy firing failure:** any inability to restart, reevaluate, or genuinely resolve an
  M17 firing lifecycle is a BLOCKER.
- **ID/correlation drift, v1 webhook drift, or legacy API drift:** each is a BLOCKER.
- **Rollback misrepresentation:** do not approve release without an explicit first-v2-
  write/data-loss runbook.
- **CI budget:** report measured pressure as debt; do not remove semantics to fit time.
- **Scope discovery:** any need for severity, generic rules, new storage schema, new route,
  multi-node authority, or another settled non-goal requires an owner decision.

## Independent plan and implementation review

Planning closure requires a fresh independent read-only reviewer to assess design
fidelity, overlooked compatibility hazards, dependency direction, persistence and
rollback, legacy firing safety, API and webhook compatibility, smoke feasibility, test
completeness, security/privacy, and accidental scope expansion. Report `BLOCKER`, `HIGH`,
`MEDIUM`, and `LOW`; fix every BLOCKER/HIGH in this file, and resolve or explicitly accept
each MEDIUM/LOW with justification.

Implementation closure requires another fresh reviewer after all code, tests, docs,
smoke, and local gates are complete. It must inspect the final diff and runtime evidence,
not reuse the planning review. The configured reviewer role is preferred. If its fixed
model cannot run, use a fresh separate supported-model read-only reviewer and record the
fallback. M18 cannot be marked complete with an unresolved BLOCKER or HIGH.

## Planning closure record

The configured architecture role could not start because its fixed model was unavailable;
a fresh supported-model read-only architecture inspection was used instead. The dedicated
observability inspection later encountered an account usage limit; direct repository
inspection plus the backend, frontend, DevOps, and product-documentation inspections
covered the planning boundary. This is not implementation evidence: the pinned
VictoriaMetrics feasibility probe remains an explicit implementation stopping gate.

The configured reviewer role also could not start because its fixed model was unavailable.
A fresh separate supported-model read-only reviewer completed the required fallback
review. Initial findings were `BLOCKER 0 / HIGH 3 / MEDIUM 3 / LOW 0`. All were resolved
in this plan: configured/observation windows are now separate types; aggregate creation
requires the expected window union; provider failure semantics are tabulated; canonical
ranks are explicit and excluded from IDs; frozen v1 lifecycle coverage includes retained
active evidence under an unavailable latest evaluation; and the pinned VictoriaMetrics
fixture has a concrete sample/tolerance recipe. A remediation re-review found one HIGH
stale type reference; it was corrected. Final independent review counts are
`BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0`. Accepted planning debt: none.

Final status must remain either `M18 PLANNED — READY FOR IMPLEMENTATION` after the review
and plan-only checks pass, or `M18 PLANNING BLOCKED — DECISION REQUIRED` if a settled
requirement cannot be planned safely.
