# Milestone 017 — Alert Notification Disposition and Delivery Status

Status: COMPLETE

## Purpose and operator outcome

An operator inspecting a durable alert episode can already see M14 canonical transition
history and M16 acknowledgement, but cannot see what Geordi decided about notification
for each transition or the current durable status of matched delivery work. M17 enriches
the existing episode-detail read model so the operator can distinguish matched,
suppressed, unrouted, and absent disposition evidence and, when delivery evidence
exists, inspect its bounded durable state.

Operator story:

> From an alert episode, I can understand whether notification was matched,
> suppressed, or unrouted and, when delivery exists, inspect its current bounded
> durable status without changing delivery.

M17 is read-only from the operator perspective. It does not add a delivery command,
retry control, routing mutation, or a new public endpoint.

## Implementation and verification record

Local implementation, backend/frontend quality gates, migration and smoke evidence,
final diff inspection, and independent implementation review are complete. ADR-020 and
the OpenAPI detail contract record the implemented boundary. This plan does not record
M17 as complete because authoritative GitLab revalidation remains pending.

## Authoritative baseline and planning boundary

This plan was prepared from a clean `main` worktree at
`8755b7ad0d35af74d275aad237c5ba86113e4f1d` (`fix(alerts): harden M16
acknowledgement contracts`). A live fetch of authoritative GitLab `origin/main`
resolved to the same commit. M1–M16 and post-M16 hardening are complete.

At planning time this file was the only changed artifact; no production code,
migrations, tests, OpenAPI, frontend, CI/CD, or ADR had then been created. Implementation
uses this baseline and must repeat the authoritative baseline checks if `origin/main`
advances before a release/merge decision.

The implementation must remain a module-internal extension of the modular monolith.
H2, JDBC, Flyway, Spring transaction types, and stored rows remain in outbound adapters;
the domain and application layers retain vendor-neutral types and inward dependency
direction.

## Authority model and final product semantics

The authority boundaries are deliberately complementary:

- M14 `alert_transition_history` is authoritative for canonical transition identity,
  payload, episode membership, type, and occurrence time.
- M11 `alert_notification_outbox` is authoritative for mutable delivery work and its
  current state, attempts, and delivery timestamps.
- M13 remains authoritative for routing-decision semantics.
- M17 `alert_notification_disposition` is authoritative only for the immutable
  notification disposition decided when an M17 transition committed.

Persisted disposition values are exactly:

```text
MATCHED
SUPPRESSED
UNROUTED
```

`NOT_RECORDED` is read-model only and must never be persisted. Its exact meaning is:
"Geordi has no durable notification-disposition fact for this transition." It is not
proof that the transition predates M17, and it must not be reconstructed from current
routing configuration.

The detail projection is all-or-nothing and follows this table:

| Durable evidence | Public projection |
| --- | --- |
| persisted `MATCHED` plus valid exactly correlated delivery | `MATCHED` plus real delivery status |
| persisted `SUPPRESSED` and no delivery | `SUPPRESSED`, delivery `null` |
| persisted `UNROUTED` and no delivery | `UNROUTED`, delivery `null` |
| no disposition and no delivery | `NOT_RECORDED`, delivery `null` |
| no disposition and exactly correlated historical delivery | `NOT_RECORDED` plus real delivery status |
| persisted `MATCHED` with missing or invalid delivery | invariant failure, sanitized `503` |
| persisted `SUPPRESSED`/`UNROUTED` with any delivery | invariant failure, sanitized `503` |
| same-ID historical delivery whose canonical payload does not match | invariant failure, sanitized `503` |

After V7, only an M17-capable Geordi writer is supported against the upgraded database.
Mixed pre-M17 and M17 writers against one V7 database are unsupported. The current
single-node topology is the deployment invariant; do not add writer-version columns,
provenance tables, migration-generation markers, historical backfill, or runtime old-
writer detection. Absence always projects as `NOT_RECORDED`.

## Domain and cohesive transition commit intent

Add the persisted domain value:

```text
NotificationDisposition
- MATCHED
- SUPPRESSED
- UNROUTED
```

Add its companion fact:

```text
AlertNotificationDisposition
- AlertTransitionId transitionId
- NotificationDisposition disposition
```

The fact must not duplicate episode ID, policy ID, transition timestamp/type,
destination, delivery state, or a disposition timestamp. M14 provides transition facts;
M11 provides delivery facts.

Replace the transition portion of `AlertLifecycleRepository.commit(...)` with one
cohesive value:

```text
AlertTransitionCommitIntent
- AlertHistoryMutation history
- NotificationCommitIntent notification

NotificationCommitIntent (closed type)
- Matched(NotificationDelivery delivery)
- Suppressed
- Unrouted
```

Use `Optional<AlertTransitionCommitIntent>` only for the entire transition intent.
Lifecycle writes that legitimately have no canonical transition pass `Optional.empty()`.
The model must make `MATCHED` without exactly one delivery and non-matched dispositions
with a delivery unrepresentable.

Construction validates that history and delivery, when present, describe the same
canonical transition and identity. The persistence adapter may defensively revalidate
at its trust boundary, but it must not accept separate history, delivery, and disposition
optionals.

Java generic erasure means the old three-argument overload taking
`Optional<NotificationDelivery>` cannot coexist with a new overload taking
`Optional<AlertTransitionCommitIntent>`. Convert the port, service, H2 adapter,
telemetry decorator, and test doubles in one compile-coherent slice. Remove the old
four-argument history/delivery overload as well so there is no bypass around disposition
recording. Compatibility is behavioral and data-level, not preservation of an internal
Java method signature.

## Canonical identity compatibility

`AlertTransitionId.from(transition)` and `NotificationDelivery.stableId(transition)`
currently independently hash the same UTF-8 text:

```text
policyId + "\n" + transitionType.name() + "\n" + occurredAt
```

M17 makes their equality an explicit invariant. Preserve the formula and all existing
delivery IDs, but refactor:

```text
NotificationDelivery.stableId(transition)
  -> AlertTransitionId.from(transition).value()
```

Before the delegation change, add fixed known-ID regression vectors for both APIs using
the same nanosecond transition fixture. After the refactor, prove each fixed value is
unchanged and both values remain byte-for-byte identical. Do not alter timestamp string
rendering, hashing input, charset, digest, or lowercase hexadecimal encoding.

## V7 persistence and upgrade safety

Create during implementation:

`backend/src/main/resources/db/migration/V7__create_alert_notification_disposition.sql`

with exactly the additive schema:

```sql
CREATE TABLE alert_notification_disposition (
    transition_id VARCHAR(64) PRIMARY KEY,
    disposition VARCHAR(16) NOT NULL,

    CONSTRAINT alert_notification_disposition_transition_fk
        FOREIGN KEY (transition_id)
        REFERENCES alert_transition_history (transition_id),

    CONSTRAINT alert_notification_disposition_value_check
        CHECK (disposition IN ('MATCHED', 'SUPPRESSED', 'UNROUTED'))
);
```

There is no backfill, delivery ID, episode/policy duplication, timestamp, destination
data, mutable delivery-state copy, cascade, or rewrite of V1–V6.

RED-first migration coverage must prove:

- clean V1 through V7 installation;
- populated V6 to V7 upgrade;
- preservation of lifecycle, episode, transition-history, acknowledgement, and outbox
  rows and values;
- zero disposition rows after upgrade;
- FK rejection of a disposition for an unknown transition;
- primary-key rejection of a second disposition for one transition;
- `NOT NULL` rejection;
- CHECK rejection of `NOT_RECORDED`, unknown, and malformed stored values.

The existing migration integration test has latest-version assertions that currently
expect V6. Keep historical V6 tests pinned to target 6 where their purpose is V6, and
add deliberate V7 latest-head assertions rather than allowing V7 to change their meaning
incidentally.

## Atomic transaction boundary and routing translation

Routing stays in `AlertLifecycleService` before persistence. For each attempted winning
transition, call `AlertRoutingPort.route(transition)` exactly once and translate its
closed decision:

```text
RoutingDecision.Matched(destination)
  -> NotificationCommitIntent.Matched(
       NotificationDelivery.pending(transition, destination, clock.instant()))
RoutingDecision.Suppressed -> NotificationCommitIntent.Suppressed
RoutingDecision.Unrouted   -> NotificationCommitIntent.Unrouted
```

Pair that result with `AlertHistoryMutation.from(transition)` in one
`AlertTransitionCommitIntent`. A routing exception reaches no repository write and
persists nothing. A no-transition lifecycle write does not route and uses an empty
transition intent.

The H2 adapter performs the winning commit under its existing `TransactionTemplate`:

```text
BEGIN
  1. insert lifecycle state, or CAS-update the expected version
  2. CAS loss -> mark rollback-only -> return false
  3. apply the M14 episode/history mutation
  4. insert the M17 disposition fact
  5. for Matched only, insert the M11 delivery/outbox row
COMMIT
```

Equivalent internal ordering is acceptable only if the same invariants and foreign-key
requirements hold. Lifecycle transition, M14 episode/history, M17 disposition, and the
optional matched M11 outbox row must commit or roll back as one unit. Serialization,
history, disposition, delivery/outbox, FK/CHECK, and other persistence failures must
leave no partial lifecycle version, episode, history, disposition, or outbox work.

On a CAS loss, the service retries from newly loaded state according to its existing
bounded retry loop. Work built for the losing attempt is not persisted. A retry may
route only if recomputation still produces a new canonical transition; already committed
transitions are never rerouted. M13 routing meanings do not change.

When adapting rollback tests, use valid cohesive intents and inject failures at the
persistence boundary. A current collision fixture constructs a delivery with a prior
transition's ID; the new type invariant should reject that before transaction entry, so
that fixture cannot remain the proof of database rollback.

## Notification-evidence read port and legacy correlation

Add a narrow application output port, conceptually
`AlertNotificationEvidenceQuery`, that accepts the bounded set of M14
`AlertTransitionId` values for one episode and returns internal application records with
enough evidence to validate:

- disposition row presence and persisted value;
- delivery row presence and ID;
- parsed canonical delivery transition/payload;
- delivery state and attempts;
- created, next-attempt, and completed timestamps;
- the evidence needed for exact legacy correlation.

Do not return JDBC rows or expose destinations, fingerprints, payload JSON, claim tokens,
or lease expiries to the web adapter. The detail currently loads at most two canonical
transitions; query all requested IDs in one bounded operation, preferably a single
parameterized snapshot query joining disposition and outbox evidence. Preserve row
absence explicitly. Do not issue one query per transition and do not use current routing
configuration on the read side.

For a transition without an M17 disposition, expose a historical delivery only when:

1. `delivery_id == transition_id`; and
2. the parsed persisted delivery transition equals the complete M14 canonical
   `AlertTransition` value.

Compare canonical values, not raw JSON lexical form. SQL `occurred_at` equality is not
decisive: V2 outbox timestamps and V4 history timestamps have different historical
precision. Cover nanosecond values and second-boundary rounding. If no disposition and
no delivery exist, return `NOT_RECORDED` with no delivery. If exact legacy delivery
exists, return `NOT_RECORDED` with its real state; never infer `MATCHED`. A same-ID row
with payload mismatch is `correlation_invalid`, not evidence to hide.

Malformed disposition, delivery state, canonical payload, identity, attempts, or required
state timestamp is an application/persistence invariant failure. Translate it to a
bounded `AlertHistoryPersistenceException` invariant kind or a focused equivalent before
the controller advice: a raw `IllegalArgumentException` currently maps to `400`, which
would misclassify corrupted durable evidence.

## Episode-detail application and API projection

Extend only:

```http
GET /api/alert-episodes/{episodeId}
```

Keep `GET /api/alert-transitions` and its public transition DTO/schema byte-for-byte
compatible. Introduce a detail-specific enriched transition model in the application and
a detail-specific response DTO in the web adapter; do not add notification fields to the
shared list DTO.

Conceptual detail shape:

```json
{
  "episode": {},
  "acknowledgement": null,
  "transitions": [
    {
      "id": "...",
      "episodeId": "...",
      "policyId": "...",
      "type": "ALERT_STARTED",
      "previousState": "INACTIVE",
      "currentState": "FIRING",
      "occurredAt": "...",
      "evaluation": {},
      "notification": {
        "disposition": "MATCHED",
        "delivery": {
          "state": "PENDING",
          "attempts": 0,
          "createdAt": "...",
          "nextAttemptAt": "...",
          "completedAt": null
        }
      }
    }
  ]
}
```

Allowed disposition values are `MATCHED`, `SUPPRESSED`, `UNROUTED`, and read-only
`NOT_RECORDED`. Delivery is `null` unless truthful delivery evidence exists. Names may be
simplified to repository conventions during implementation, but semantics require owner
review before change.

HTTP behavior remains:

| Situation | Response |
| --- | --- |
| valid consistent detail | `200 OK` |
| invalid episode ID | `400 Bad Request` |
| absent episode | `404 Not Found` |
| persistence unavailable or malformed/inconsistent notification projection | sanitized `503 Service Unavailable` |

Reuse the RFC 9457 `application/problem+json` boundary. Do not expose SQL messages,
exception messages, malformed values, destination internals, payload content, or partial
episode data. M17 does not add a partial-availability envelope.

## Delivery-state and timestamp semantics

Public meanings are:

- `PENDING`: durable delivery work exists and is waiting for its next eligible claim.
- `LEASED`: an attempt has been claimed and completion is not durably recorded. It may
  already be expired and awaiting recovery, so do not call it simply “in progress.”
- `DELIVERED`: Geordi observed an accepted HTTP 2xx response and durably recorded
  success. This does not prove human receipt, downstream processing, or exactly-once
  network delivery.
- `FAILED`: durable delivery processing terminated unsuccessfully. M17 has no persisted
  diagnostic reason.
- `attempts`: claims consumed before HTTP execution; it does not prove the same number
  of receiver invocations.

The existing M11 domain object retains `nextAttemptAt` internally for every state. The
M17 public mapper must mask fields by state rather than changing M11 storage/domain
invariants:

| State | `createdAt` | `nextAttemptAt` | `completedAt` |
| --- | --- | --- | --- |
| `PENDING` | present | present | `null` |
| `LEASED` | present | `null` | `null` |
| `DELIVERED` | present | `null` | present |
| `FAILED` | present | `null` | present |

Never expose `claimToken` or `leaseExpiresAt`.

## Frontend scope

Extend the existing `AlertEpisodeDetail` transition article with a compact Notification
section. Preserve investigation links, episode bookmark behavior, acknowledgement UI,
cached-detail warning, Retry detail behavior, and list/detail failure isolation. Add no
mutation control.

Render disposition labels exactly:

| Value | Label |
| --- | --- |
| `MATCHED` | Matched |
| `SUPPRESSED` | Suppressed |
| `UNROUTED` | No matching route |
| `NOT_RECORDED` | Not recorded |

Render delivery labels truthfully:

| Value | Label |
| --- | --- |
| `PENDING` | Pending |
| `LEASED` | Leased — completion not recorded; may await reclaim |
| `DELIVERED` | Delivered — Geordi recorded an accepted HTTP response |
| `FAILED` | Failed — no detailed cause was recorded |

Label attempts as “Claims consumed” and show only the state-relevant timestamps from the
table above. Safe text rendering must not gain destination, delivery ID, payload, claim,
lease, header, credential, or error-detail fields.

## Security and privacy boundary

M17 remains operator read-only and does not add authentication, authorization, RBAC,
SSO, or trusted operator identity. M16 acknowledgement identity remains unrelated and
caller-asserted. Acknowledging an episode has no effect on disposition or delivery.

Neither API, UI, logs, traces, metrics, nor sanitized errors may disclose:

- destination ID or fingerprint;
- delivery ID;
- webhook URL, headers, credentials, or tokens;
- claim or lease token and lease expiry;
- raw payload JSON or response body;
- arbitrary HTTP error or exception text.

## Bounded self-observability and health

Add only telemetry for work newly owned by M17:

- disposition/transition commit outcome;
- notification projection query outcome;
- projection integrity failure.

Use low-cardinality outcomes such as `success`, `persistence_failure`, and
`invariant_failure`, and only the required bounded integrity reasons such as
`matched_delivery_missing`, `unexpected_delivery`, `correlation_invalid`, and
`stored_value_invalid`. Prefer one stable outcome dimension per instrument over adding
every possible attribute.

Never label M17 telemetry with policy ID, episode ID, transition ID, delivery ID,
service, destination, URL, actor, reason, error text, or exception text. Do not duplicate
M11 delivery attempt, result, retry, or duration metrics. Update the observed repository
decorator and Spring wiring with the new cohesive commit contract; do not leave old
commit overloads as unobserved escape routes.

Extend the Alerts persistence availability probe with a bounded zero-row query against
`alert_notification_disposition`. With Alerts enabled, missing/unreadable V7 schema makes
Alerts health and readiness down through the existing health composition. The probe does
not validate row-by-row business integrity or mutate data.

## RED-first test matrix

Implementation follows RED → GREEN → REFACTOR. Each slice adds a meaningful failing
behavior test before production changes.

### Domain and application

- `Matched` commit intent contains exactly one delivery for the same canonical
  transition.
- `Suppressed` and `Unrouted` have no API by which a delivery can be supplied.
- no-transition lifecycle writes remain valid and do not route.
- history transition ID and matched delivery ID agree.
- each routing decision maps exactly once to the matching closed intent.
- routing exceptions write nothing.
- CAS-loss attempts leave no disposition/outbox/history work and preserve retry
  semantics without rerouting a committed transition.

### Identity

- fixed `AlertTransitionId` regression vector;
- fixed `NotificationDelivery` ID regression vector;
- byte-for-byte equality of both IDs;
- unchanged values after `NotificationDelivery.stableId(...)` delegates.

### Persistence and migration

- clean V1 → V7 and populated V6 → V7;
- no disposition backfill and preservation of lifecycle/history/ACK/outbox data;
- PK, FK, CHECK, and `NOT NULL` enforcement;
- rollback independently injected at lifecycle, history, disposition, and outbox steps;
- atomic matched history/disposition/delivery commit;
- suppressed and unrouted commits have disposition but no delivery;
- CAS loss rolls back the entire transition intent;
- Alerts persistence health includes V7.

### Legacy and read model

- no disposition and no delivery → `NOT_RECORDED`, delivery `null`;
- no disposition plus exactly correlated delivery → `NOT_RECORDED` plus real status;
- identity match plus canonical payload mismatch → sanitized invariant failure;
- exact correlation survives nanosecond timestamps and second-boundary rounding;
- changing current routing configuration never reconstructs historical disposition;
- all four real delivery states project with valid attempts and masked timestamps;
- `SUPPRESSED`, `UNROUTED`, and `NOT_RECORDED` project exactly;
- persisted `MATCHED` without valid delivery and non-matched disposition with delivery
  fail as sanitized `503`;
- malformed disposition/state/payload/timestamps fail as sanitized `503`;
- the bounded detail query does not perform N+1 reads;
- no secret or internal field reaches the application web model.

### Controller and API compatibility

- existing episode detail remains `200` with enriched detail transitions;
- invalid ID `400`, missing episode `404`, and sanitized RFC 9457 `503`;
- detail only contains notification projection;
- `/api/alert-transitions` response schema and fixtures remain unchanged;
- response JSON omits every forbidden internal field and persistence/error value.

### Frontend

- all four disposition labels and all four delivery labels;
- truthful `LEASED` and `FAILED` wording;
- “Claims consumed” rather than attempt/invocation claims;
- state-dependent timestamp presence and absence;
- no destination or internal fields;
- investigation links, acknowledgement flow, bookmarks, cached-detail warning, retry,
  and list/detail isolation remain green.

## Expected implementation file inventory

Repository inspection identifies the following existing files as the expected change
surface. New files use the established package naming; implementation may collapse a
new application record into a closely related file when that is demonstrably smaller,
but must not broaden the surface without recording why.

### Backend production and migration

- `backend/src/main/java/io/geordi/alerts/domain/NotificationDisposition.java` — new
  persisted enum.
- `backend/src/main/java/io/geordi/alerts/domain/AlertNotificationDisposition.java` —
  new immutable companion fact.
- `backend/src/main/java/io/geordi/alerts/domain/NotificationCommitIntent.java` — new
  closed matched/suppressed/unrouted type.
- `backend/src/main/java/io/geordi/alerts/domain/AlertTransitionCommitIntent.java` — new
  cohesive transition intent and cross-fact invariants.
- `backend/src/main/java/io/geordi/alerts/domain/NotificationDelivery.java` and
  `AlertTransitionId.java` — behavior-preserving identity delegation/authority.
- `backend/src/main/java/io/geordi/alerts/application/port/out/AlertLifecycleRepository.java`
  — replace independent optional contracts.
- `backend/src/main/java/io/geordi/alerts/application/AlertLifecycleService.java` —
  translate routing once and build the cohesive intent.
- `backend/src/main/java/io/geordi/alerts/application/port/out/AlertNotificationEvidenceQuery.java`
  — new bounded batch read port.
- `backend/src/main/java/io/geordi/alerts/application/AlertNotificationEvidence.java`
  and detail-specific notification/delivery projection records — new internal read
  models; keep persistence rows out of the web adapter.
- `backend/src/main/java/io/geordi/alerts/application/AlertEpisodeDetail.java` and
  `AlertHistoryQueryService.java` — enrich detail and enforce projection invariants.
- `backend/src/main/java/io/geordi/alerts/application/AlertHistoryPersistenceException.java`
  — reuse/extend bounded persistence versus invariant classification if required.
- `backend/src/main/java/io/geordi/alerts/adapter/out/persistence/H2AlertLifecycleRepository.java`
  — V7 insert, atomic commit, one batch evidence query, exact payload correlation, and
  health probe.
- `backend/src/main/java/io/geordi/alerts/adapter/out/telemetry/ObservedAlertHistoryRepository.java`
  and, only if separation is clearer, one focused notification-projection observer.
- `backend/src/main/java/io/geordi/alerts/adapter/spring/AlertsModuleConfiguration.java`
  — port and decorator wiring.
- `backend/src/main/java/io/geordi/alerts/adapter/in/web/AlertHistoryController.java`
  — detail-specific DTO without changing list DTO.
- `backend/src/main/java/io/geordi/alerts/adapter/in/web/AlertHistoryExceptionHandler.java`
  — preserve sanitized `400`/`404`/`503` classification.
- `backend/src/main/resources/db/migration/V7__create_alert_notification_disposition.sql`.

### Backend tests

- `backend/src/test/java/io/geordi/alerts/domain/NotificationDeliveryTest.java` and a
  focused commit-intent/domain test for fixed identity and sum-type behavior.
- `backend/src/test/java/io/geordi/alerts/domain/AlertHistoryMutationTest.java` — retain
  identity agreement coverage.
- `backend/src/test/java/io/geordi/alerts/application/AlertLifecycleServiceTest.java` —
  routing translation, no-transition, CAS retry/loss, and no reroute.
- `backend/src/test/java/io/geordi/alerts/application/AlertHistoryQueryServiceTest.java`
  — new focused projection/correlation/integrity tests (the service currently lacks a
  dedicated test file).
- `backend/src/test/java/io/geordi/alerts/adapter/out/persistence/H2AlertLifecycleRepositoryTest.java`
  — atomicity, batch reads, state rows, constraints, corruption, and rollback.
- `backend/src/test/java/io/geordi/alerts/adapter/out/persistence/AlertHistoryV3ToV4MigrationIntegrationTest.java`
  — pin historical latest-version assumptions where needed; prefer a new focused
  `AlertNotificationDispositionV7MigrationIntegrationTest.java` for V6/V7 concerns.
- `backend/src/test/java/io/geordi/alerts/adapter/in/web/AlertHistoryControllerTest.java`
  — enriched detail, unchanged transition list, status/error/privacy contracts.
- `backend/src/test/java/io/geordi/alerts/adapter/out/telemetry/ObservedAlertHistoryRepositoryTest.java`
  and focused projection telemetry tests if a new decorator is introduced.
- `backend/src/test/java/io/geordi/alerts/adapter/spring/AlertsModuleConfigurationTest.java`
  and `AlertLifecyclePersistenceHealthIntegrationTest.java` — wiring and V7 health.
- existing architecture tests only if a new rule is needed to enforce the port/adapter
  boundary; do not add a ceremonial rule.

### Frontend

- `frontend/src/api/alertHistory.ts` and `alertHistory.test.ts` — detail-only types and
  transport fixtures.
- `frontend/src/features/alert-history/AlertEpisodeDetail.tsx` — compact read-only
  notification section.
- `frontend/src/features/alert-history/alertHistoryPresentation.ts` and
  `alertHistoryPresentation.test.ts` — bounded labels and timestamp selection.
- `frontend/src/features/alert-history/AlertHistoryPage.test.tsx` — integration-level
  preservation of detail, links, ACK, cache warning, retry, and isolation.
- `frontend/src/styles.css` only if existing detail styles cannot express the compact
  section accessibly.

### Operations, API, ADR, and documentation

- `scripts/verify-alert-history.ps1` — extend the existing semantic smoke.
- `docs/api/openapi.yaml` — detail-specific notification schemas and sanitized `503`;
  preserve `/api/alert-transitions`.
- proposed `docs/adr/ADR-020-alert-notification-disposition-and-delivery-status.md`.
- `docs/architecture/NOTIFICATION_DELIVERY.md` and
  `docs/architecture/ALERT_LIFECYCLE.md`.
- `docs/product/PRD.md`, `docs/product/ROADMAP.md`, and `README.md`.
- `docs/architecture/ARCHITECTURE.md` or `MODULES.md` only if implementation materially
  changes their current-state descriptions.
- `.gitlab-ci.yml` and Compose files are not expected to change; reuse existing smoke
  wiring and validation unless implementation evidence proves a narrowly required edit.

Do not repair the known LOW historical V5 width example in
`docs/plans/MILESTONE-016.md` as part of M17. Track it as separate documentation
housekeeping.

## Baby-step implementation sequence

1. **RED — cohesive domain intent.** Add tests for the three closed notification cases,
   no-transition validity, cross-transition rejection, and history/delivery identity;
   implement only the new domain values.
2. **RED — identity compatibility.** Freeze known IDs for both APIs, then delegate
   `NotificationDelivery.stableId` to `AlertTransitionId` and rerun all M11/M14 identity
   tests.
3. **RED — port conversion.** Convert repository contract, lifecycle service, observed
   decorator, H2 adapter signatures, and test doubles together so erasure cannot create
   an old/new overload bridge. Initially prove the adapter rejects/unimplemented V7 work.
4. **RED — V7 migration.** Add clean V1→V7, populated V6→V7, preservation, no-backfill,
   and constraint tests; add only the V7 SQL and turn them green.
5. **RED — atomic writes.** Add valid-intent success and injected-failure tests for each
   transactional step, then implement history → disposition → optional outbox insertion
   inside the existing transaction.
6. **RED — routing translation.** Prove once-per-attempt mapping, routing exception
   isolation, no-transition behavior, and CAS-loss retry; implement the service mapping
   without changing M13.
7. **RED — evidence read/correlation.** Add the bounded port/model and persistence tests
   for absence, exact legacy payload equality, nanoseconds, rounding, mismatches,
   malformed rows, and one batch query; implement without current-route inference.
8. **RED — application projection.** Test all disposition/delivery combinations,
   state-dependent timestamps, and sanitized invariant classification; enrich
   `AlertEpisodeDetail` with detail-specific transitions.
9. **RED — controller/API DTO.** Test `200`/`400`/`404`/`503`, forbidden-field absence,
   and unchanged `/api/alert-transitions`; implement the detail mapper.
10. **RED — telemetry and health.** Test bounded outcomes/reasons and forbidden label
    absence, then extend the decorator/wiring and V7 health probe without duplicating
    M11 metrics.
11. **RED — frontend.** Add API, presentation, and page tests for exact wording,
    timestamps, privacy, and regression behaviors; implement the compact section.
12. **OpenAPI.** Add only episode-detail notification components and exact RFC 9457
    responses. Validate that the transition-list schema is unchanged.
13. **Semantic smoke.** Extend `verify-alert-history.ps1`; do not create a parallel
    delivery-management framework.
14. **ADR and documentation.** Create ADR-020 and synchronize current-state delivery,
    lifecycle, PRD, roadmap, and README documentation. Do not mark M17 complete yet.
15. **Local closure.** Run focused tests after every slice, then the complete closure
    gate below.
16. **Fresh independent review.** Delegate read-only implementation review to the
    configured reviewer; use a fresh supported-model reviewer if its fixed model is
    unavailable. Resolve all BLOCKER/HIGH and explicitly resolve or accept MEDIUM/LOW,
    rerun affected gates, inspect the final diff, then record closure evidence.

## Semantic smoke extension

Extend `scripts/verify-alert-history.ps1` and its existing M14/M15/M16 lifecycle,
restart, database-inspection, and UI/API evidence. The M17 smoke must prove:

1. a populated V1–V6 database upgrades to V7;
2. the upgrade creates no disposition backfill;
3. a legacy transition without delivery returns `NOT_RECORDED` and no delivery;
4. an exactly correlated legacy delivery returns `NOT_RECORDED` plus real status;
5. a new matched transition persists `MATCHED` plus delivery;
6. new suppressed and unrouted transitions persist their exact disposition without
   delivery;
7. matched delivery progresses through its supported durable states with truthful
   state-dependent fields;
8. disposition and delivery status survive backend restart;
9. deterministic success reaches terminal `DELIVERED`;
10. terminal `FAILED` is asserted only if deterministic fixture support already exists
    or can be added narrowly;
11. injected `MATCHED` without delivery makes the whole detail return sanitized `503`;
12. responses contain no forbidden destination, delivery, payload, claim, lease, secret,
    or error data;
13. M16 acknowledgement leaves disposition and delivery unchanged;
14. existing M14/M15/M16 semantic regression remains green.

Use direct database setup/inspection only where the existing smoke already establishes
that operational pattern. Do not add manual retry, cancellation, redrive, global delivery
search, or broad delivery-management smoke behavior.

## ADR implementation record

Implementation adds
`docs/adr/ADR-020-alert-notification-disposition-and-delivery-status.md`, the next
available number after ADR-019. The decision defines:

- immutable companion disposition authority versus M14 transition and M11 mutable
  delivery authorities;
- the closed transition commit intent and atomic boundary;
- `NOT_RECORDED` as absence of fact, not a pre-M17 claim;
- exact legacy identity plus canonical-payload correlation and timestamp-precision
  rationale;
- the supported single M17-writer-after-V7 model;
- all-or-nothing integrity failure behavior;
- public state/timestamp semantics and the disclosure boundary.

The ADR preserves ADR-019/M14 transition-history authority, M11 delivery-state
authority, and ADR-018/M13 routing semantics.

## Explicit non-goals and maintenance boundary

M17 does not include failure-reason persistence, an HTTP attempt ledger, manual retry,
redrive, cancellation, dead-letter queue, acknowledgement-aware delivery, silencing,
maintenance windows, escalation, assignment, comments, incident management, destination
identity exposure, multiple destinations, a global delivery dashboard/search, new
notification channels, retention deletion, runtime routing or policy CRUD, auth/RBAC,
multi-node delivery ownership, distributed scheduling, framework upgrades, SCA/SBOM
implementation, or M18 work.

Existing backend dependency vulnerability triage and authenticated/cached SCA/SBOM
automation remain HIGH-priority non-blocking technical debt. Do not mix that maintenance
into M17. If implementation discovers a confirmed urgent applicable vulnerability, stop
and report it separately; do not perform a Spring Boot upgrade under this milestone.

## Complete local closure gate

Run from the repository root unless a subdirectory is stated:

1. `git diff --check` and an explicit changed-file inventory.
2. Backend: from `backend`, `./mvnw -B -ntp verify` (or `./mvnw.cmd` on native Windows).
   This must include JUnit, ArchUnit, PMD, SpotBugs, and Find Security Bugs.
3. Focused identity, V7 migration/upgrade, atomicity/rollback, correlation, controller,
   telemetry, and persistence-health tests with their results recorded.
4. Frontend: from `frontend`, `npm ci`, `npm test`, `npm run typecheck`, `npm run lint`,
   and `npm run build`.
5. OpenAPI 3.1 validation plus duplicate YAML-key rejection; explicitly compare the
   `/api/alert-transitions` schema to prove it did not change.
6. `docker compose config` for the base file and every maintained overlay, including
   `compose.m10.yaml`, `compose.m12.yaml`, `compose.m13.yaml`, and `compose.m14.yaml` in
   the same combinations used by repository/CI validation.
7. Clean V1→V7 and populated V6→V7 migration tests, preservation/no-backfill/constraint
   proofs, and V7 persistence-health tests.
8. Extended M17 alert-history semantic smoke and applicable M14/M15/M16 regression
   smoke, including restart durability and ACK independence.
9. Search generated/runtime output and public responses for forbidden secret/internal
   fields and high-cardinality M17 telemetry labels.
10. Inspect the full final diff, synchronize ADR/OpenAPI/product/architecture/README
    documentation, and ensure no speculative M18 or unrelated SCA/SBOM work entered.
11. Fresh independent read-only implementation review reporting `BLOCKER`, `HIGH`,
    `MEDIUM`, and `LOW`. Resolve BLOCKER/HIGH before closure; resolve each MEDIUM/LOW or
    document an explicit accepted-debt justification and rerun affected gates.

Do not make unrelated SCA/SBOM automation an M17 closure gate.

## Local implementation evidence

Local closure completed against baseline
`56b29ccb6f343218bec01f4d1ed61ded72781fef` without commit or push:

- backend `mvnw.cmd -B -ntp verify`: 363 tests, zero failures/errors/skips; PMD,
  SpotBugs, and Find Security Bugs passed;
- frontend `npm ci`, tests, typecheck, lint, and build: 219 tests passed and all
  gates succeeded;
- focused migration/rollback coverage: 46 tests passed, including clean V1→V7 and
  populated V6→V7 preservation, zero disposition backfill, constraints, and atomic
  rollback injection;
- extended deployed alert-history smoke passed M17 disposition/delivery durability,
  privacy, integrity, legacy correlation, restart, and M14/M15/M16 regressions;
- OpenAPI 3.1 parsing and duplicate-key rejection passed, and the
  `/api/alert-transitions` path/schema are byte-for-byte unchanged from the baseline;
- base plus maintained M10/M12/M13/M14 Compose configurations rendered successfully;
- `git diff --check`, PowerShell parsing, public-field searches, and bounded telemetry
  label inspection passed;
- fresh post-remediation independent review: BLOCKER 0, HIGH 0, MEDIUM 0, LOW 0.

The accepted MEDIUM evidence debt is limited to harness structure: the deployed smoke
creates a clean V7 database and then removes disposition facts to exercise runtime
legacy behavior; it does not itself stage a populated V6 database. The dedicated
migration integration suite directly proves populated V6→V7 preservation and zero
backfill, while the smoke proves the distinct deployed runtime behaviors. This avoids
embedding a second migration-test framework in the semantic smoke and does not defer a
production defect. Authoritative GitLab revalidation remains required before M17 may be
marked complete.

## Risks, review focus, and owner decisions

Primary risks and mitigations:

- **False history reconstruction:** absence is always `NOT_RECORDED`; current routing is
  never consulted.
- **Partial transition facts:** one cohesive intent and one transaction eliminate
  independent optional combinations.
- **ID drift:** fixed regression vectors precede the delegation refactor.
- **Legacy false correlation:** require both identical ID and equal parsed canonical
  transition, never decisive SQL timestamp equality.
- **State/time leakage:** the application projection masks M11 internal timestamps and
  never exposes claim/lease or destination fields.
- **Wrong client error:** corrupted rows become bounded invariant failures before web
  exception mapping and therefore sanitized `503`, not `400`.
- **N+1/state tearing:** load the episode's bounded evidence in one batch/snapshot query.
- **Internal contract escape:** remove old commit overloads and update the primary
  telemetry decorator and all test doubles in the same slice.

The approved product/technical direction resolves the implementation semantics. There
are no unresolved owner decisions at planning time. Any implementation evidence that
would require changing the disposition meanings, schema, authority boundaries, legacy
correlation rule, API semantics, privacy boundary, or supported writer model must stop
for owner review rather than silently revising this plan.

## Plan validation and implementation review requirement

Planning closure requires a full diff inspection, `git diff --check`, confirmation that
only this file changed, contradiction searches for `NOT_RECORDED`, `MATCHED`, mixed
writers, V7, M14 authority, M11 authority, authentication, and non-goals, plus a fresh
independent read-only plan review for architecture, atomicity, type safety, migration,
legacy truthfulness, identity, API compatibility, privacy, tests, and scope.

Implementation is not locally complete until the configured reviewer agent performs a
fresh independent read-only review. If its fixed model is unavailable, use a fresh
separate supported-model reviewer. The final implementation report must state counts for
`BLOCKER`, `HIGH`, `MEDIUM`, and `LOW`; all BLOCKER/HIGH findings must be fixed, while
MEDIUM/LOW require explicit resolution or accepted-debt justification.

## Closure

**Status:** COMPLETE

Milestone 17 was authoritatively revalidated on GitLab.

Implementation commit:

`295c66ac63cad71a4fddf279842640f411e84dd7`

Authoritatively validated commit:

`28da26822e1dfcc65e53bf68d9e7ff4c7736c01d`

Verified backend artifact SHA-256:

`3ed140c533b5054ca7f9ee6cb272691161a4b67c0f0faa888fd02f7ad8724513`

Validation:

- Backend: 363 tests passed.
- PMD, SpotBugs, and Find Security Bugs passed.
- Frontend pipeline passed.
- Deployment configuration validation passed.
- `local_stack_smoke` passed.
- M17 semantic smoke passed.
- M16 acknowledgement regression passed.
- M14 alert-history regression passed.
- Artifact revision and SHA-256 provenance were verified before runtime image construction.
- Independent implementation review: BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0.

Accepted evidence debt:

The deployed semantic smoke does not itself stage a populated V6 database.
Populated V6 -> V7 preservation and zero-backfill remain proven by the dedicated
migration integration suite.

Milestone 17 is COMPLETE.