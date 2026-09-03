# Milestone 014 — Alert Episode & Transition History Foundation

Status: M14 COMPLETE

## Objective

Persist one durable firing episode and immutable canonical transition history per
policy while preserving M9 evaluation, M10 lifecycle, M13 routing, and M11 worker
semantics. Operators can answer when an episode started/resolved and which transitions
belong to it without reevaluation or mutation.

## Scope and architecture

Alerts remains the bounded context. Domain additions are value objects with real
invariants: `AlertEpisodeId`, `AlertEpisode` (normal or explicit legacy origin), and
`AlertTransitionRecord`; application owns mutation/query use cases and ports; H2/JDBC,
Flyway, web, Micrometer and JSON are adapters. No vendor type crosses inward.

For each transition: M10 derives it; M14 creates an unpersisted mutation intent; M13
routes it; then the existing repository transaction CAS-writes lifecycle plus episode
and ledger, and appends M11 work only for `MATCHED`. Routing failure precedes the
transaction. CAS loss rolls everything back and retries. The M11 worker stays outside.

No transition, stale/duplicate evidence, unavailable evidence, and disabled policy
produce no M14 row. A normal start must open exactly one episode and record STARTED;
a normal resolution must close that one episode and record RESOLVED. Inconsistent
storage is failed closed, observed, and never repaired implicitly.

## Persistence and upgrade

Add additive Flyway migrations for `alert_episode` and `alert_transition_history`,
followed by pre-release integrity and nanosecond-precision hardening: foreign key linkage,
deterministic unique transition identity, and a DB-backed one-open-episode-per-policy
constraint. Normal M14 rows require `opened_at`; only explicit
legacy-origin rows may have unknown start. Use deterministic UTF-8 newline-delimited,
UTC-`Instant.toString()` SHA-256 hex identifiers: M11's exact policy/type/occurrence
encoding for transitions. Normal episode identity is
`hex(SHA-256(policyId + "\\n" + startedAt.toString()))`. Legacy
`PRE_M14_UNKNOWN_START` identity is
`hex(SHA-256(policyId + "\\nPRE_M14_UNKNOWN_START\\n" + resolvedAt.toString()))`,
using only the genuine canonical resolution fact; it never fabricates a start timestamp
or STARTED transition. The explicit discriminator separates normal and legacy identity
namespaces, while M11's policy/type/occurrence encoding remains the transition identity.
They contain no route/destination information.

Do not backfill history. Existing firing lifecycle rows are explicitly untracked until
the first genuine resolution, which creates/closes a legacy-origin episode with unknown
start and writes the real resolution record. Never invent a start time or transition.

## Read contract and UI

Add bounded, read-only episode list/detail and transition-list endpoints described in
ADR-019. Use deterministic newest-first ordering with a transition-ID tie-breaker;
maximum half-open range is 31 days where a policy/episode does not already narrow the query;
`from`/`to` are paired RFC 3339 UTC instants with `from < to`, and invalid input returns
the existing 400 Problem contract. Query membership is occurrence time for transitions
and start time for episodes (legacy unknown-start episodes require policy scope), with
maximum results of 100 episodes/200 transitions. No UI in M14: lifecycle stays a
current-state page and history is an API foundation.

## Observability, privacy, and retention

Instrument bounded open/resolve, persistence/query outcomes, and invariant violations;
labels must never contain identity, routes, destinations, URLs, secrets, arbitrary error
text, or raw payload. Persist only transition-safe canonical context (policy, state/type,
time, service identity, window/range and condition); never payloads, endpoint data,
tokens, routing decisions, or delivery status. Extend persistence health checks.

There is no automatic retention deletion in M14. Bounded reads limit operational load;
count/age cleanup and its operational policy are deferred.

## Semantic smoke

| Case | Independent assertion |
| --- | --- |
| Start/retry | One M10 STARTED, one open episode, one ledger row; repeat/CAS retry adds none. |
| Resolve | Same episode closes, one RESOLVED row, canonical duration and ordering coherent. |
| No transition/unavailable | No row; unavailable freezes firing and fabricates nothing. |
| Restart | Open and closed history survive H2/Compose restart. |
| Routing | MATCHED retains M11 durable binding; SUPPRESSED/UNROUTED commit history without outbox; outcomes unchanged. |
| Privacy/query | No secret/endpoint in store/API; limits, ranges and stable ordering enforced. |
| Upgrade | Pre-M14 firing has no fabricated start; genuine resolution has explicit legacy unknown-start episode. |
| Legacy identity | Retry and restart of one legacy resolution retain its deterministic legacy ID; a following normal start has its independent normal ID, and the discriminator prevents ambiguity. |

The isolated smoke uses the existing local fixtures only—no additional external
service—and runs after the existing M9–M13 semantic chain. Its
`scripts/verify-alert-history.ps1` gate is wired immediately after M13 in GitLab CI.
Local closure validation on 2026-09-03 passed the exact M14 smoke on a clean rebuilt
runtime image, including direct durable-row inspection, and then passed the ordered
M9–M13 regression chain. Legacy determinism, no fabricated start, subsequent normal
identity, and corruption fail-closed behavior are covered by focused
persistence/domain tests in addition to the isolated normal-lifecycle smoke.

### Authoritative closure evidence

The authoritative GitLab pipeline checked out implementation commit
`ed766a46b7c51ee1c54b844bbf6de5a79fab1efb` from `main` and passed all jobs. Its
Windows `local_stack_smoke` verified that the backend artifact revision matched
`CI_COMMIT_SHA`, verified the artifact SHA-256 before constructing the runtime image,
passed the existing M9–M13 semantic regression chain, and passed
`pwsh -File ./scripts/verify-alert-history.ps1 -TimeoutSeconds 480`. Cleanup completed
and the job succeeded.

### Historical investigation

During pre-closure local validation, one direct H2 inspection reported zero normal
episode rows after an otherwise successful smoke. This remains recorded as a historical,
non-reproducible **LOW harness false-negative**, not an active blocker. Controlled
forensic reproduction proved API and direct-H2 durability, repeated clean local M14
smoke runs passed, and the authoritative GitLab M14 smoke passed. No product data-loss
defect was reproduced.

## Implementation sequence and regression gates

1. RED domain/application tests for episode invariants, IDs, legacy behavior and query bounds.
2. Extend the transactional repository port/adapter, migration and health probe; prove rollback,
   CAS, duplicate-key and restart behavior.
3. Add API/OpenAPI/controller/query tests, then the isolated smoke and deployment docs.
4. Update ALERT_LIFECYCLE, NOTIFICATION_DELIVERY, API, README/Compose guidance and relevant debt.
5. Run full Maven verify (JUnit, ArchUnit, PMD, SpotBugs, Find Security Bugs), M9–M13 regressions,
   M14 smoke, Compose/config validation, `git diff --check`, and independent review. Frontend
   tests/typecheck/lint/build are not required unless UI scope changes.

## Closure criteria

The atomic invariant holds for every canonical transition; no provider is re-evaluated by reads;
all stated smoke cases and gates pass; documentation matches behavior; no BLOCKER/HIGH review
finding remains. Do not add retention automation, UI, incident workflow or M15 features.

## Risks and trade-offs

The two-table design adds a transactional seam and conservative failure behavior, but makes
episodes/querying explicit and avoids event sourcing. Deterministic IDs make retry safe but
depend on M10's existing unique canonical occurrence semantics. Deferred retention leaves
storage growth to an explicit later operational decision. The legacy upgrade policy is honest
but cannot display duration for alerts already firing before M14.
