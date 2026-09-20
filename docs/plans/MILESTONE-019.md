# M19 — Authenticated Operator Access and Authorization Foundation

Status: PLANNED / READY FOR IMPLEMENTATION

## Planning authority and scope

Authoritative planning baseline: `cf6030ad70f862ae41c2154270040fd5e01f8285`.
On 2026-09-20, `git rev-parse HEAD main origin/main` returned that SHA for all
three references and `git status --short` was empty. No material baseline contradiction
was found. M19 design status supplied by the owner is **M19 DESIGN READY FOR PLANNING**.
The contracts below are settled implementation requirements, not alternatives.

This task creates only `docs/plans/MILESTONE-019.md`. It does not implement M19,
create V8 or ADR-022, change tests/code/frontend/OpenAPI/Compose/CI, commit, or push.
All paths and classes described below are future implementation work unless explicitly
identified as existing. Implementation must recheck the baseline and stop on concrete
contradictions rather than silently adapting the security design. Intermediate slices
are not deployable releases; external exposure is permitted only after closure gates.

## Purpose and verified starting state

Operators sign in through an external OIDC provider and a backend-managed browser
session. API/CI callers present validated access tokens. Both produce one canonical
application principal with explicit permissions. Reads, acknowledgement, and manual
lifecycle evaluation have separate permissions; scheduling remains trusted in-process
work. New ACK facts have durable authenticated attribution, while old caller assertions
remain explicitly legacy. This is not an identity-management or generic audit product.

Repository evidence inspected at the baseline:

| Existing location | Verified starting fact / implementation consequence |
| --- | --- |
| `backend/pom.xml` | Java 21, Spring Boot 3.5.7, web/actuator/JDBC/H2/Flyway; no OAuth starters. Preserve Boot version. PMD, SpotBugs/Find Security Bugs run at verify. |
| `backend/src/test/java/io/geordi/architecture/ArchitectureTest.java` | Core is framework-independent; bootstrap cannot depend on concrete optional modules. Add rules without weakening existing rules. |
| `docs/api/openapi.yaml` and application controllers | OpenAPI 3.1.0, 23 operations, no application authentication. Header currently says milestone-17; M19 reconciles it with the actual contract. |
| `backend/src/main/resources/db/migration/` | Latest migration is `V7__create_alert_notification_disposition.sql`; no V8. M18 changed durable JSON compatibility, not schema version. |
| `alerts/application/AcknowledgeAlertEpisodeService.java` | Actor is caller supplied; actor and reason use `String.strip()`, empty reason becomes null, reason maximum is 512 code points. |
| `alerts/domain/AlertEpisodeAcknowledgement.java` | Existing fact contains episode ID, actor, reason, timestamp; actor maximum 128 code points. |
| `alerts/adapter/out/persistence/H2AlertLifecycleRepository.java` | ACK storage/read projection and episode-row serialization are existing authorities; preserve ACK/RESOLVE concurrency. |
| `alerts/adapter/spring/AlertsModuleConfiguration.java` | Current manual/scheduler lifecycle entry shares SingleFlight and observed execution. Preserve one coordinator after entry separation. |
| `frontend/src/api/client.ts`, `main.tsx`, `App.tsx` | Handwritten contracts; GET/POST helper, query retry currently 1, no auth bootstrap. |
| `frontend/src/features/alert-history/`, `features/alert-lifecycle/` | Existing ACK actor UI, detail projection and Evaluate-now are the bounded UI change points. |
| `frontend/nginx.conf`, `compose.yaml` | Current HTTP frontend proxy covers `/api/`, forwards caller Host/forwarding information, and backend is loopback-published. M19 must replace the supported ingress topology. |
| `backend/src/main/resources/application.yml` | Health exposed, readiness includes readinessState/geordiPlatform. Preserve operational semantics, constrain details and disable discovery. |
| `otel/otel-collector-config.yaml`, `backend/Dockerfile` | Detailed debug exporter for traces/metrics; pinned OTel Java Agent 2.28.1. Redaction after storage/export is too late. |
| `.gitlab-ci.yml`, `scripts/verify-*.ps1` | Ordered exclusive Windows Compose job, verified JAR/image provenance, 30-minute job and 27-minute script budgets. M16/M17 are embedded in history smoke; preserve those assertions. |
| `docs/plans/MILESTONE-018.md`, `docs/product/PRD.md`, `ROADMAP.md` | M1–M18 complete; owner-authoritative M18 integration approximately 24m36s, backend 438 tests. Historical evidence, not rerun in this planning task. |

Java paths abbreviated to `alerts/...` above are relative to
`backend/src/main/java/io/geordi/`. Relevant existing architecture/operations documents
are `MODULES.md`, `ALERT_LIFECYCLE.md`, `SELF_OBSERVABILITY.md` under
`docs/architecture/`, and `deploy/README.md`.

## Architecture and trust boundaries

```text
browser -> OIDC code + PKCE -> validated identity -> bounded server session --+
API/CI  -> RFC 9068 resource-server validation -----------------------------+-> canonical principal
canonical principal -> HTTP policy -> authorized application command -> existing domain
scheduler -> trusted internal application entry -> shared lifecycle coordinator
```

Pure contracts belong to `io.geordi.core.application.security`: `PrincipalIdentity`,
`AuthenticatedPrincipal`, `GeordiPermission`, `AuthenticationMechanism`, and a small
permission-checking service/exception if needed. No Spring, servlet, `Jwt`, `OAuth2User`,
OIDC/provider, JSON, HTTP-client, or OTel SDK types enter these contracts or domain.
Use `io.geordi.bootstrap.security` for protocol/configuration adapters and composition
that depend only on core contracts, never on concrete Alerts classes. Alerts composition
stays in `alerts.adapter.spring.AlertsModuleConfiguration`. Security observation adapters
may live under `selfobservability.adapter`; preserve core/bootstrap independence rules.
If that placement is used, expose a pure observation port in core and inject it into
bootstrap security adapters; never import self-observability implementations into bootstrap.

Alerts application translates canonical issuer/subject/display name into an Alerts-owned
attribution value before domain/persistence calls. Alerts domain cannot depend on core
security. HTTP controllers may depend only on external authorized mutation interfaces,
not the internal lifecycle entry, coordinator, raw mutation services or repository ports.
Scheduler may depend only on the trusted lifecycle entry. No header, request field,
principal mechanism, role or route can select internal authority. ArchUnit and Spring
wiring tests prove these restrictions, including transitive delegate wiring.

Suggested composition:

```text
AuthorizedAcknowledgeAlertEpisodeUseCase(principal, episodeId, reason)
  -> permission check -> Alerts attribution -> shared ACK service/repository
AuthorizedManualLifecycleEvaluationUseCase(principal, policyId)
  -> permission check -> shared SingleFlight(observed lifecycle service)
TrustedInternalLifecycleEvaluationUseCase(policyId)
  -> same shared SingleFlight(observed lifecycle service)
```

The old credential-free lifecycle interface must not remain injectable into web code.
Keep the common executor out of controller injection; use explicit bean qualifiers/types
and a context test to prevent accidental bypass. Do not duplicate lifecycle logic or
create a fake scheduler principal. Mutation authorization is a pure application check,
not merely a controller annotation or Spring authority check.

## Canonical identity, permissions and mapping

`AuthenticatedPrincipal` has `PrincipalIdentity identity`, nullable `String displayName`,
an immutable `Set<GeordiPermission> permissions`, and mechanism `SESSION` or `BEARER`.
Identity equality is exactly issuer + subject. Do not normalize those strings after
validation, and never use email/name/grant/scope/Spring authority as identity.

| Value | Frozen validation |
| --- | --- |
| issuer | Absolute HTTPS URI, at most 2048 ASCII characters, no credentials/query/fragment; exact comparison, no URI normalization. |
| subject | 1..255 printable ASCII characters, not whitespace-only. |
| displayName | Optional; at most 128 Unicode scalar values, no controls; empty, invalid, unpaired surrogate or excessive value becomes null. |

| Permission | Public spelling | Bundle membership |
| --- | --- | --- |
| `OBSERVABILITY_READ` | `observability:read` | VIEWER, OPERATOR, EVALUATOR |
| `ALERT_ACKNOWLEDGE` | `alerts:acknowledge` | OPERATOR |
| `ALERT_EVALUATE` | `alerts:evaluate` | EVALUATOR |

Bundles are deployment configuration conveniences only. Exactly these permissions:
no ADMIN, wildcard, CONFIGURATION_ADMIN or implicit read grant from mutation permission.
Test a principal with only each mutation permission, not only bundled identities.

Provider-neutral configuration under `geordi.security` names issuer, API audience,
browser client ID/secret reference, public-base-url, one top-level grant claim and an
explicit external-value-to-permissions map. API audience differs from browser client ID.
The grant claim must be an array of at most 100 strings, each at most 128 Unicode scalar
values; malformed shape rejects authentication. Absent claim gives zero permissions;
unknown value grants nothing. Session mapping uses validated ID-token claims, bearer
mapping uses validated access-token claims. Never merge scopes, scp, roles, groups or
Spring authorities. Invalid mapping/configuration fails startup; no disabled-auth mode.
Secrets use mounted/runtime secret input and never configuration dumps or command echo.

## Complete HTTP operation policy

All 23 existing application operations are enumerated below. R = OBSERVABILITY_READ,
A = ALERT_ACKNOWLEDGE, E = ALERT_EVALUATE. Both valid mechanisms are accepted unless
otherwise specified. Every GET in this table also allows HEAD with identical security,
status and headers but no body. HEAD never executes a mutation.

| # | Method | Existing path | Permission |
| --- | --- | --- | --- |
| 1 | GET | `/api/platform` | R |
| 2 | GET | `/api/modules` | R |
| 3 | GET | `/api/platform/health` | R |
| 4 | GET | `/api/metrics/services` | R |
| 5 | GET | `/api/metrics/overview` | R |
| 6 | GET | `/api/metrics/series` | R |
| 7 | GET | `/api/traces/services` | R |
| 8 | GET | `/api/traces` | R |
| 9 | GET | `/api/traces/{traceId}` | R |
| 10 | GET | `/api/logs/services` | R |
| 11 | GET | `/api/logs` | R |
| 12 | GET | `/api/service-map` | R |
| 13 | GET | `/api/slos` | R |
| 14 | GET | `/api/slos/{sloId}` | R |
| 15 | GET | `/api/slos/{sloId}/evaluation` | R |
| 16 | GET | `/api/alert-policies` | R |
| 17 | GET | `/api/alert-policies/{policyId}/evaluation` | R |
| 18 | POST | `/api/alert-policies/{policyId}/lifecycle-evaluations` | E |
| 19 | GET | `/api/alert-states` | R |
| 20 | GET | `/api/alert-episodes` | R |
| 21 | GET | `/api/alert-episodes/{episodeId}` | R |
| 22 | POST | `/api/alert-episodes/{episodeId}/acknowledgements` | A |
| 23 | GET | `/api/alert-transitions` | R |

| Additional route | Exact allowed method / policy |
| --- | --- |
| `/api/me` | GET/HEAD; authentication only, zero permissions allowed. |
| `/api/auth/csrf` | GET only; authenticated SESSION, no extra permission. |
| `/api/auth/logout` | POST only; authenticated SESSION + CSRF. |
| `/actuator/health/liveness`, `/actuator/health/readiness` | GET/HEAD anonymous, status-only response. |
| `/actuator/health` | GET/HEAD, authenticated + R. |
| `/oauth2/authorization/geordi` | GET only, anonymous login initiation with bounded admission. |
| `/login/oauth2/code/geordi` | GET only, anonymous protocol callback with mandatory transaction validation. |
| SPA shell and built assets | Explicit GET/HEAD frontend route/asset allowlist; no catch-all API/protocol/management fallback. |
| Everything else, including unlisted methods | Deny; no handler or state mutation. |

No broad `/api/**`, `/actuator/health/**` or `/error` permitAll. Disable actuator discovery
and expose no other management endpoints. Error dispatch must render a bounded response
without granting a new request access to `/error`. Test normal/error/forward dispatch,
path normalization, trailing slash, encoded separators, TRACE/OPTIONS/PUT/PATCH/DELETE
and POST-to-read paths. Authenticated denied requests return bounded 403; absent/invalid
authentication on protected routes returns 401. Unsupported protocol methods are denied,
not silently handled as GET. Do not redirect API 401 to login.

Liveness/readiness do not acquire transient IdP reachability contributors. Existing
platform readiness semantics remain; exact anonymous probe responses reveal only status.
Explicit management detail policy must not leak component details on probe subpaths.

## Credential selection and request ordering

Before operation execution, inspect raw credential multiplicity (including what nginx
coalesces), then resolve existing session without creating one:

1. Duplicate/coalesced/multiple Authorization credentials: 400.
2. Duplicate `__Host-GEORDISESSION` cookies: 400, including duplicate equal values.
3. Valid authenticated session plus any Authorization header: 400.
4. Authorization present without authenticated session: bearer authentication only;
   unsupported/malformed scheme is 401. Never fall back after invalid bearer.
5. Authorization absent: use valid session if present, otherwise unauthenticated.
6. Expired/unknown session cookie does not block a valid bearer. Never merge identities
   or permissions. A prelogin session is not an authenticated session.

Test actual multiple headers and raw Cookie fields over the nginx/backend path, not only
MockMvc. Do not trust a proxy header claiming authentication or precomputed principal.
CSRF/logout reject a valid BEARER principal with 403.

Processing order is credential syntax -> authentication -> route permission -> session
CSRF -> deserialization/validation -> resource lookup -> command authorization + command.
Application authorization checks precede repository/lookup side effects even when called
directly. Invalid ACK body or unknown episode must not reveal application information
to unauthorized users. Filter ordering must return missing/expired session 401 before
CSRF 403, and missing permission before body validation. Test each competing failure.

## JWT and trusted remote metadata contracts

RFC 9068 access-token adapter requirements:

- Compact signed JWS only; RS256 only, RSA >=2048 bits; `typ` is `at+jwt` or
  `application/at+jwt`; exact configured issuer and configured API audience.
- Required `iss`, `sub`, `aud`, `exp`, `iat`, `client_id`, `jti`; validate `nbf` if present.
  Use 60-second clock skew; `exp > iat`, declared lifetime <=1 hour. Validate claim
  types and time relationships, including future issued-at beyond skew.
- Required `kid`, nonempty and at most 128 characters. `client_id` and `jti` are nonempty
  printable strings <=255. Token <=16 KiB before parsing/remote work.
- Reject none, HMAC, JWE, unknown critical JOSE members, duplicate JSON members in
  header/payload, token-selected key URLs, wrong token purpose and ID tokens presented
  to API even if otherwise signed by a trusted key. Keys come only from trusted metadata.
- JOSE details stay in adapter tests. Do not assume default Spring/Nimbus validation
  proves this profile; configure/extend bounded parsing and validators explicitly.

Discovery/JWKS use HTTPS with certificate validation, no redirects, 2-second connect
and 5-second total operation timeout. Discovery <=64 KiB; JWKS <=256 KiB, <=32 keys,
unique kid, valid usable signing key material. Validate metadata issuer exactly and
trusted HTTPS endpoints; never derive discovery from untrusted token issuer. Enforce
response bounds while streaming, not after unbounded buffering.

Startup requires valid configuration, discovery and usable trusted keys. Normal JWKS
refresh every 5 minutes; maximum usable set age 15 minutes from last successful fetch,
not last failed attempt. Unknown-kid refresh at most once per 30 seconds, coalesced
across concurrent requests. Successful refresh atomically replaces the prior set;
removed keys cannot resurrect from per-key/decoder caches. If a trusted cached key is
still usable, validate locally during outage. Unknown key after successful refresh is
401. Dependency unavailable with no usable trusted key is 503. Invalid token remains
401 when invalidity is independently established; outage never permits authentication.
Use injected time/concurrent tests, not real five-/fifteen-minute sleeps.

## OIDC, session, origin and CSRF contracts

Browser login is confidential-client authorization code using `client_secret_basic`,
mandatory PKCE S256, state, nonce, single-use transaction with five-minute lifetime,
`response_mode=query`, and exact callback `{public-base-url}/login/oauth2/code/geordi`.
Validate ID-token signature, issuer, audience, azp, times and nonce; reject callback
replay, missing/mismatched/expired transaction, code substitution and token endpoint
failure. Do not apply access-token typ requirements to legitimate OIDC ID tokens.
No UserInfo or offline_access. On success rotate session ID and redirect only to `/`.
Disable arbitrary saved requests and returnUrl. Consume transaction atomically.

After principal construction, discard access/refresh/ID tokens and raw claim set; do not
retain `OidcUser` or token-bearing authorized-client state in SecurityContext, session,
repository, request cache or completion handlers. Retain only canonical principal and
bounded session metadata. Test reachable session/authorized-client state and failure
cleanup, not only the response DTO. Transient code/verifier/state/nonce exist only for
the bounded transaction and are removed on consumption/expiry.

Server-side in-memory single-node sessions use exactly `__Host-GEORDISESSION` with
Secure, HttpOnly, SameSite=Lax, Path=/ and no Domain. Idle timeout 30 minutes; absolute
timeout one hour from login, never activity-extended; restart invalidates sessions.
Admission is atomic, max 1024 total including prelogin, max 128 pending prelogin.
Cleanup every 60 seconds and before admission. No eviction of valid authenticated
sessions to accept attempts. Capacity exhaustion returns 503 + `Retry-After: 30`.
Login rotation must transfer capacity accounting atomically; callback failure/expiry,
logout and restart release resources. No implicit container-created uncounted sessions.
No Redis or SQL session store.

`public-base-url` is authoritative: HTTPS origin only, no path/query/fragment/userinfo.
Use it for callback/redirect/origin checks. Disable backend forwarded-header strategy.
nginx rejects unknown Host, strips inbound Forwarded/X-Forwarded-* and sets controlled
proxy values. Do not build security URLs from Host or forwarded headers. No trusted
identity headers. Same-origin frontend/API only; no wildcard CORS, arbitrary origin
list or cross-origin SPA support. Validate deployment/runtime API-base configuration.

CSRF is a session-bound 32-random-byte base64url synchronizer token:

```json
{"headerName":"X-CSRF-TOKEN","token":"..."}
```

GET `/api/auth/csrf` is SESSION-only, authentication-only, `Cache-Control: no-store`.
Frontend holds it only in memory. Rotate on login/session rotation and remove on logout
or expiry; new session needs new bootstrap. Valid session with missing/invalid token on
mutation is 403; missing/expired session is 401 before CSRF. Mutation Origin, if present,
must equal configured public origin. Valid bearer-only mutations are cookie-CSRF-exempt;
they still obey the Origin rule when Origin is present. Never disable CSRF globally.
Logout POST requires SESSION + CSRF, invalidates session/token, expires the same cookie,
returns 204 with no-store, and performs no IdP-wide logout or arbitrary redirect.

GET/HEAD `/api/me` returns only identity `{issuer, subject}`, nullable displayName,
permissions sorted lexicographically by public spelling, and `authMode: SESSION|BEARER`.
It requires authentication but no R permission and has no-store. No email, external
grants, raw claims, token or session identifier is returned.

## Failure, transport and observability contracts

Use RFC 9457 `application/problem+json` with fixed type/title/detail mappings and no-store.
Do not echo request target/query into problem `instance`; use an omitted instance or
fixed safe route category. Bearer 401 has a sanitized WWW-Authenticate challenge.

| Status | Bounded condition |
| --- | --- |
| 400 | Ambiguous credentials/duplicate session cookie; ACK actor or unknown property after security succeeds. |
| 401 | Missing/invalid/expired authentication; malformed bearer, signature/issuer/audience/purpose/mandatory identity failure. |
| 403 | Missing permission, failed CSRF on valid session, BEARER against SESSION-only endpoint, denied route/method for authenticated user. |
| 503 | Authenticity cannot be established due unavailable dependency; session admission exhausted (Retry-After 30). |

Configuration failure is startup failure. No security error includes token, claim set,
algorithm detail, JWKS URI, IdP exception, session ID, code, state, secret or stack trace.
Coordinated nginx/container/parser limits: JWT 16 KiB, individual header 32 KiB,
aggregate headers 64 KiB, request target 8 KiB. Oversize headers return 431, target 414,
without echoed input. Test boundary and one-byte-over via both supported ingress and
backend. A framework/proxy default returning 400 for oversize must be corrected; do not
claim that increasing a buffer alone implements separate per-field and aggregate limits.

Counters: `geordi.security.authentication.attempts` and
`geordi.security.authorization.decisions`. Dimensions are closed mechanism, result,
fixed reason and fixed endpoint category. Categories exactly: read, acknowledge,
evaluate, me, login, callback, csrf, logout, probe, denied. Define enums and exhaustive
test of allowed values; use a fixed NONE/AMBIGUOUS telemetry mechanism where no canonical
principal exists, not a new AuthenticationMechanism. Count once at the owning decision
boundary; test filters/error dispatch do not double-count. Keep platform resource tags.

Structured security logs use the same bounded event/result/reason categories without
raw exception text. Never record issuer, subject, username, email, group, jti, token,
cookie, session ID, OAuth code/state, client secret, IP, policy ID, episode ID, dynamic
path or raw exception in security logs/metric dimensions. No generic audit ledger.

Credential leak prevention is an acceptance gate before live protocol tests. Suppress
or sanitize authentication-path `url.full`, `url.query`, `http.target`, Authorization,
Cookie, Set-Cookie, bodies, token responses and credential-bearing exception messages
at the source, including agent-generated outbound token-exchange spans. Defense in
depth Collector filtering must run before detailed debug and Tempo export; verify the
pinned Collector supports any selected processor before relying on it. Do not remove
all self-telemetry or hide evidence by disabling the pipeline.

nginx access logs use safe route categories without query/headers; error logs must not
emit raw authentication request lines even on malformed/oversize requests. If nginx
cannot sanitize a diagnostic class, suppress that sensitive diagnostic source and
retain separate bounded error counters. Inspect backend/HTTP client debug logging and
framework exceptions. CI after_script currently prints Compose logs: replace this with
bounded safe diagnostics only after scanning, not raw logs followed by a late scan.

Sentinel test must inspect browser/frontend console, nginx access/error logs, backend
logs, HTTP errors, exported OTel spans/events/attributes, Collector detailed debug,
Tempo queries, CI command echo/failure diagnostics and every publishable artifact.
Use recognizable test token/code/state/cookie/secret sentinels, plus raw and encoded
forms. Scan in private ephemeral storage; report only channel/count, never matches.
Inject a harmless unique positive control into every inspected channel/pipeline; prove
expected span reaches Collector and Tempo and expected safe log reaches diagnostics.
An empty/missing capture fails. Exercise success, malformed callback, dependency failure,
401/403, duplicate credentials, oversize and CI failure cleanup paths. A deliberate
synthetic-leak negative control must prove scanner failure without publishing its input.

## ACK compatibility, migration and replay

Freeze V7 ACK fixtures and original INSERT/API examples before edits. Future migration
`backend/src/main/resources/db/migration/V8__add_authenticated_acknowledgement_attribution.sql`
adds to existing `alert_episode_acknowledgement` (created by V5, Unicode columns widened
by `V6__widen_alert_episode_acknowledgement_unicode_columns.sql`):

```sql
identity_provenance VARCHAR(32) NOT NULL DEFAULT 'LEGACY_CALLER_ASSERTED'
principal_issuer VARCHAR(2048) NULL
principal_subject VARCHAR(255) NULL
display_name_snapshot VARCHAR(256) NULL
```

Existing actor VARCHAR(256) NOT NULL, reason VARCHAR(1024) NULL, episode_id and
acknowledged_at remain unchanged. Closed provenance values are LEGACY_CALLER_ASSERTED
and AUTHENTICATED_PRINCIPAL. SQL CHECK must explicitly use IS NULL/IS NOT NULL:
authenticated requires nonnull/nonempty issuer and subject; legacy requires issuer,
subject AND snapshot null. Unknown provenance and partially populated combinations
fail. Test SQL UNKNOWN cannot accidentally satisfy the check. Domain/adapter bounds
also enforce canonical identity and <=128-scalar snapshot; verify supplementary Unicode
fits the selected H2 VARCHAR behavior without changing existing actor/reason bytes.

Old rows acquire only legacy default; no identity backfill or rewriting actor/reason/time.
Old INSERT omitting new columns yields legacy only. New writer explicitly writes
authenticated provenance. Implement dual-read before any authenticated writes; keep
frozen legacy behavior in internal compatibility tests, never expose a legacy command
over HTTP after cutover. Corrupt/unknown provenance fails boundedly, never guessed.

Alerts owns attribution variants. Existing actor remains a display projection:
valid display-name snapshot, otherwise literal `Authenticated principal`. Never join
issuer/subject into actor. Do not re-strip/normalize a valid name snapshot through the
old actor-input normalization. Response adds `attribution` with provenance, identity,
displayName. Authenticated identity is populated; legacy identity/displayName are null
and actor is unchanged. API types do not reveal SQL column names/layout.

ACK request is `{ "reason": "..." }` or `{}`; reason remains optional/nullable.
Any actor presence including null and any unknown property yields 400 only after
security checks. Use a strict ACK request decoder/DTO; do not globally change unrelated
JSON compatibility. Preserve reason strip, empty->null, maximum 512 code points.

| Persisted state / command | Outcome |
| --- | --- |
| Open episode, no ACK | 201 new authenticated fact |
| Same issuer+subject, same normalized reason | 200 original fact |
| Same subject, different issuer | 409 |
| Different identity or normalized reason | 409 |
| Only display name changed | 200 original timestamp and original name/actor snapshot |
| Existing legacy ACK, any authenticated command | 409; never claim/upgrade by actor matching |
| Closed episode, even exact replay | 409 |

Preserve one ACK per episode, episode-row locking, ACK/RESOLVE serialization and all
M10–M18 lifecycle/history/outbox/routing/evidence semantics. Restart must retain new
attribution and old legacy rows. ACK changes no delivery or lifecycle authority.

## Dependency-ordered implementation slices

For each slice write meaningful behavioral/architecture tests first (RED/GREEN), or
alongside adapter configuration when test-first is impractical. Proposed test paths are
specified in the test matrix below. Do not mark a slice accepted merely because it
compiles. Stop conditions are gates, not permission to omit remaining work.
Test-category references in early slices mean the applicable foundation subset;
later slices complete their integration coverage. Final full-matrix acceptance is
explicitly assigned to Slice 9 and full pipeline/CI proof to Slices 11–12.

### Slice 0 — Freeze baseline and compatibility evidence

- Purpose/contracts: record actual V7 legacy facts, API shape and concurrency before
  changing ACK types; all existing M9–M18 semantics remain authoritative.
- Files: proposed `backend/src/test/resources/io/geordi/alerts/adapter/out/persistence/compatibility/ack-v7.sql`
  and `ack-v7-api.json`; existing service/domain/repository/controller tests and this plan.
- Steps: recheck refs/status, inventory migrations/23 routes/bean graph; freeze original
  INSERT and Unicode/null reason/time fixtures from baseline, record baseline gates.
- Tests: legacy roundtrip, normalization and ACK/RESOLVE tests; test matrix 16–18.
- Depends on: none. Accept when frozen evidence passes on baseline and provenance is
  recorded. Stop on contradictory schema/API/authority; do not regenerate fixtures from
  changed M19 models or silently bless their output.

### Slice 1 — Canonical application contracts and ownership

- Purpose/contracts: immutable identity/principal/permission values and Alerts attribution
  variants; application permission checks; no protocol types in pure layers.
- Files: new `core/application/security/*`, `alerts/domain/AlertAcknowledgementAttribution.java`,
  existing `AlertEpisodeAcknowledgement.java`; `architecture/ArchitectureTest.java`.
- Steps: implement bounds/equality and explicit permission mapping targets; add Alerts
  attribution without making existing legacy constructors falsely authenticated.
- Tests: matrix 1, 3, 4, 17, boundary Unicode/equality and immutable permission set tests.
- Depends on: 0. Accept when pure tests and existing domain regressions pass. Stop if
  domain needs Spring/core-security/provider types or permissions are inferred.

### Slice 2 — Additive V8 and dual-read ACK repository

- Purpose/contracts: safe additive storage before writer cutover.
- Files: future V8 migration; `alerts/application/port/out/AlertEpisodeAcknowledgementRepository.java`,
  `alerts/adapter/out/persistence/H2AlertLifecycleRepository.java`, acknowledgement domain
  and history snapshot/projection as needed for dual-read; update forwarding signatures
  in `alerts/adapter/out/telemetry/ObservedAcknowledgeAlertEpisodeUseCase.java` and
  `ObservedAlertHistoryRepository.java` together; frozen fixtures stay unchanged.
- Steps: migrate, map both provenances explicitly, add internal authenticated write
  capability only once reader exists; keep public writer legacy until secure cutover.
  Introduce new signatures without deleting compatibility proof.
- Tests: matrix 16–18; empty/V7/older chain, old INSERT, constraint truth table, restart,
  Unicode, one-per-episode and ACK/RESOLVE races. Run existing migration tests too.
- Depends on: 0–1. Accept when mixed stored data is correctly readable and old rows are
  byte/semantic-preserved. Stop on any misclassification or lost serialization. No
  intermediate binary may be exposed as an authenticated M19 release.

### Slice 3 — Configuration, dependencies and early safe telemetry

- Purpose/contracts: validated `geordi.security`, fail-closed startup and safe instrumentation
  before any sentinel or token-bearing integration traffic.
- Files: future `bootstrap/security/SecurityProperties.java`, configuration validators,
  `backend/pom.xml`, `application.yml`, self-observability adapters/configuration,
  `otel/otel-collector-config.yaml`, `frontend/nginx.conf`, CI diagnostic helpers as needed.
- Steps: evaluate OAuth2 client/resource-server starters and test-scoped security-test;
  inspect transitive graph, do not explicitly add starter-security without necessity.
  Keep Boot unchanged. Define bounded error enums and source-side leak suppression;
  document secret input and strict startup validation; prepare tests with real configuration.
- Tests: matrix 2, 4, 22–23, configuration invalidity, telemetry positive/negative controls.
- Depends on: 1. Accept when secrets cannot enter default diagnostics and config rejects
  unsafe values. Stop on hidden auth bypass flags, trust-all SSL or unbounded exceptions.

### Slice 4 — Dedicated test IdP and local TLS foundations

- Purpose/contracts: one lightweight fixture reused by backend integration and Compose,
  excluded from production artifact; trusted TLS transport, no CI bypass.
- Files: proposed `deploy/oidc-fixture/`, `scripts/New-GeordiTestTls.ps1`,
  `scripts/lib/GeordiAuthentication.ps1`, `compose.m19.yaml`, base Compose/nginx and
  deployment environment examples; test-only browser harness under `frontend/e2e/`.
- Steps: implement discovery, JWKS, RSA signing, distinct access/ID tokens, code flow,
  exact redirects, client_secret_basic, S256, nonce, state roundtrip/binding, one-use
  code and invalid-claim/rotation/outage controls on test-only private control channel.
  Generate ephemeral CA/certs with deterministic names/SANs/trust setup (random keys,
  not committed fixed private material). nginx serves geordi.localhost and fixture TLS
  auth.localhost; backend resolves auth.localhost over Compose DNS with matching SAN.
  Resolve frontend/backend dependency cycle by starting TLS/fixture before backend
  discovery; nginx must tolerate backend startup without depending on backend health.
- Tests: TLS hostname/cert rejection, discovery/code fixture tests, startup-order proof;
  fixture endpoints cannot be packaged or exposed in production backend.
- Depends on: 3. Accept when browser, Java trust store and PowerShell CI explicitly trust
  generated CA without ignore flags, fixture controls are isolated, secrets stay outside
  artifacts, and cleanup removes temporary private material/trust additions on failure.
  Stop if private keys/credential URLs appear in command arguments/logs or HTTP bypass
  is needed. Defer full semantic smoke until later slices.

### Slice 5 — Bearer/discovery/JWKS adapter

- Purpose/contracts: strict RFC 9068 identity and explicit grant mapping, trusted metadata
  cache/outage behavior defined above.
- Files: proposed `bootstrap/security/jwt/*`, `bootstrap/security/metadata/*`,
  `bootstrap/security/ExternalGrantMapper.java`; test fixture support.
- Steps: bounded parse/profile validators, trusted TLS fetches, atomic replace cache,
  refresh coalescing and local-cache decisions, sanitized failures; canonical conversion.
- Tests: matrix 2, 5–7, all JWT negative cases and virtual-clock/concurrency JWKS cases.
- Depends on: 1, 3–4. Accept when no default decoder shortcut admits ID tokens/stale or
  removed keys and startup requires keys. Stop on authenticity ambiguity or fail-open.

### Slice 6 — Browser OIDC and bounded sessions

- Purpose/contracts: code+PKCE login yields only canonical principal; session lifetime,
  fixation, capacity and credential disposal meet the frozen model.
- Files: proposed `bootstrap/security/oidc/*`, `bootstrap/security/session/*` and tests.
- Steps: enforce transaction/ID token checks; use exact callback/redirect; replace default
  token-bearing state; bounded atomic session admission/rotation/cleanup; cookie policy.
- Tests: matrix 8–9, retained-state traversal, nonce/state/code replay, parallel admission,
  fixation, idle versus absolute clock tests, restart and callback-failure cleanup.
- Depends on: 1, 3–5. Accept when no post-login tokens/raw claims remain and concurrent
  limits hold. Stop on uncounted session allocation or retained authorized-client state.

### Slice 7 — Default-deny ingress and application entry separation

- Purpose/contracts: credential selection, route matrix, error/transport contract plus
  independent application mutation guards and trusted scheduler entry.
- Files: `bootstrap/security/*` filters/chain/problems, all existing web controllers
  for principal adaptation only, `alerts/application/Authorized*UseCase.java`, trusted
  lifecycle entry, `AlertsModuleConfiguration.java`, `AlertEvaluationScheduler.java`.
- Steps: implement exact path+method rules, authenticated read gates, probe policy,
  ambiguity checks before authentication and CSRF; split entries over one existing
  SingleFlight coordinator; wire controllers to authorized interfaces. ACK remains
  non-public during this integration slice until Slice 8 atomically switches the DTO
  and authenticated write path. No temporary permitted actor-input route.
- Tests: matrix 3–4, 7, 11–13, 19–20, real nginx duplicate credentials and direct wrapper
  invocation without permission; ensure both entries share overlap prevention.
- Depends on: 2, 5–6. Provisional acceptance requires implemented read/manual/probe/login
  route tests plus structural/wiring tests, and proof that ACK and unimplemented
  me/CSRF/logout routes remain denied. Do not require their future success cases here.
  The complete matrix is the combined 7–9 gate at the end of Slice 9. Stop if
  HTTP can reach internal/raw mutation, scheduler needs credentials, or security order
  allows body/resource leakage. This slice and 8–9 form one externally releasable unit.

### Slice 8 — Authenticated ACK public cutover and API contract

- Purpose/contracts: reason-only ACK, authenticated attribution, frozen replay table and
  consistent read projection; no caller actor path survives.
- Files: `AcknowledgeAlertEpisodeService.java`, authorized wrapper, ACK controller/request
  and DTO mappers in `alerts/adapter/in/web/AlertHistoryController.java`, history query
  snapshot types and `docs/api/openapi.yaml`.
- Steps: strictly reject actor presence/unknown fields after security; derive attribution
  solely from canonical principal; preserve normalized reason; enable authenticated
  writer and dual-read projection together; update status/response schemas.
- Tests: matrix 15–18, malformed unauthorized bodies, same-subject/different-issuer,
  changed name, legacy conflict, closed replay, persistence restart and concurrency.
- Depends on: 2, 7. Accept when all public new writes explicitly authenticated and legacy
  reads unchanged except additive attribution. Stop if actor matching upgrades legacy,
  a new fact is unreadable or shared lifecycle semantics change.

### Slice 9 — Me, CSRF and logout protocol

- Purpose/contracts: canonical bootstrap and session-only synchronizer-token lifecycle.
- Files: proposed `bootstrap/security/api/IdentityController.java`, CSRF/logout adapters,
  session code and OpenAPI protocol paths.
- Steps: implement me/no-store/sorted permissions; session-token bootstrap and rotation;
  enforce Origin/mutation order, logout invalidation/204, no credential-bearing responses.
- Tests: matrix 10, 14, ordering/expiry, bearer 403, zero-permission me, HEAD body absence.
- Depends on: 6–8. Accept when session mutations cannot proceed without valid CSRF and
  unauthenticated requests get 401 first. Stop on globally disabled CSRF or token reuse
  across sessions. Complete and pass the entire route matrix with the now-implemented
  authenticated ACK and real protocol endpoints; this is final acceptance of the
  combined Slices 7–9 unit, before frontend/semantic-smoke work proceeds.

### Slice 10 — Frontend bounded auth and permission UX

- Purpose/contracts: bootstrap before protected queries, canonical permission context,
  reason-only ACK and truthful legacy/authenticated display.
- Files: `frontend/src/main.tsx`, `App.tsx`, `components/AppShell.tsx`, `api/client.ts`,
  `api/types.ts`, `api/alertHistory.ts`, new `features/auth/*`, `api/auth.ts`, existing
  alert-history input/detail/tests and alert-lifecycle page/hooks/tests.
- Steps: login-required/forbidden states, login navigation, me then CSRF for sessions,
  in-memory token, logout; no permission inference from bundles; gate read queries by R,
  ACK by A, Evaluate-now by E. Remove actor input. Set 401/403 as non-provider/nonretry
  errors; do not automatically replay a mutation after login or CSRF renewal.
  Abort/ignore old principal requests using auth generation and clear TanStack Query
  caches on logout/principal change, including late responses and mutation state.
- Tests: matrix 21, delayed completion after logout/switch, zero-permission me, mutation-only
  principal, forbidden versus login-required, old ACK rendering, empty/new CSRF state.
- Depends on: 8–9. Accept when no protected query starts before auth/permission readiness
  and stale data cannot reappear. Stop on token persistence in storage or UI-only auth.

### Slice 11 — Complete telemetry, ingress and leak proof

- Purpose/contracts: end-to-end bounded observability and transport, with positive controls.
- Files: self-observability security adapters/tests, nginx/agent/Collector configuration,
  proposed `scripts/Test-GeordiCredentialLeaks.ps1`, `frontend/e2e/security.spec.ts`.
- Steps: finish counters/logs and all capture/scanner paths; test source redaction and
  Collector defense before exporters, nginx malformed/error logging, header/target
  bounds, Host/forwarded spoofing. Include downstream token client spans and failure paths.
- Tests: matrix 11–13, 22–23; sentinel controls in each channel including artifact staging.
- Depends on: 3–10. Accept only with active pipeline proof and zero leaks. Stop on any
  leak, missing capture or diagnostic artifact retaining credentials; remediate at source.

### Slice 12 — Authenticated semantic chain and CI budget evidence

- Purpose/contracts: one M19 smoke plus the complete existing ordered regressions, using
  shared credentials and one real browser login proof.
- Files: proposed `scripts/verify-security.ps1`, shared auth/TLS/leak helpers, existing
  `scripts/verify-*.ps1`, `.gitlab-ci.yml`, Compose files and test-only browser dependencies.
- Steps: implement sequence below; convert application requests to shared authenticated
  helpers, including parallel runspaces and backend/proxy calls; adapt M16 actor expectations
  deliberately, keep legacy coverage in migration tests; preserve M17/M18 semantic coverage,
  artifact provenance, cleanup and bounded diagnostics. Keep demo/provider probes distinct.
- Tests: matrix 23–25, script credential renewal without command replay, no fallback to
  anonymous, clean checkout candidate/JAR/image identity, failure cleanup exercise.
- Depends on: all runtime slices. Accept when timing ledger, complete chain and leak
  gates pass inside measured budget. Stop on skipped semantics, duplicate expensive
  provider scenarios or timeout increase without measurements and documented rationale.

### Slice 13 — ADR and documentation reconciliation

- Purpose/contracts: truthful reproducible operator/deployment/API/rollback documentation.
- Files: `README.md`, `docs/product/PRD.md`, `ROADMAP.md`, `docs/architecture/MODULES.md`,
  `ALERT_LIFECYCLE.md` (including acknowledgement/history sections), `SELF_OBSERVABILITY.md`,
  `deploy/README.md`, proposed `docs/architecture/SECURITY.md`, `docs/api/openapi.yaml`,
  future `docs/adr/ADR-022-external-identity-adapters-application-authorization-and-authenticated-alert-attribution.md`,
  this plan's implementation evidence record.
- Steps: document exact title **External Identity Adapters, Application Authorization,
  and Authenticated Alert Attribution**, configuration/trust setup, no credentials in
  examples, permissions, actor break, legacy meaning, session restart and rollback.
- Tests: OpenAPI validation and documentation-to-route/config checks (matrix 24).
- Depends on: runtime/contract shape established; maintain relevant docs alongside edits,
  final reconcile after 12. Accept when startup instructions are reproducible and no
  planned feature is claimed implemented without evidence. Stop on stale anonymous examples.

### Slice 14 — Independent implementation review and closure

- Purpose/contracts: verify all completion criteria and a fresh independent final diff.
- Files: only fixes justified by review; this plan closure evidence.
- Steps: run full gates below, review artifact/runtime provenance, configured reviewer
  read-only inspection, resolve all findings, re-run affected tests, inspect final diff.
- Tests: full backend/frontend/contracts/runtime gates, not a compile-only declaration.
- Depends on: 0–13. Accept when evidence is recorded and independent findings resolved.
  Stop on any missing evidence, regression, leak or scope expansion; record out-of-scope
  findings as debt rather than implementing M20 features.

## Concrete test matrix

Java test locations below are relative to `backend/src/test/java/io/geordi/`.
New classes are proposed; existing classes must be extended without discarding old
semantic coverage. Fast suites use real security filters with signed fixture tokens;
mock users alone cannot prove adapter authentication. Integration tests named
`*IntegrationTest` must actually execute under the existing Maven test lifecycle.

| # | Category | Files / required proof |
| --- | --- | --- |
| 1 | Canonical values | `core/application/security/AuthenticatedPrincipalTest.java`, `PrincipalIdentityTest.java`, `GeordiPermissionTest.java`: bounds, exact identity, immutable grants, no implied permission. |
| 2 | Claim mapping | `bootstrap/security/ExternalGrantMapperTest.java`, `SecurityPropertiesTest.java`: missing/unknown/malformed/bounds, startup rejection, no merged grants. |
| 3 | Application guards | `alerts/application/AuthorizedAcknowledgeAlertEpisodeUseCaseTest.java`, `AuthorizedManualLifecycleEvaluationUseCaseTest.java`: unauthorized direct calls never delegate/lookup. |
| 4 | ArchUnit/wiring | `architecture/ArchitectureTest.java`, proposed `bootstrap/security/SecurityWiringIntegrationTest.java`: pure layers, Alerts-owned attribution, no HTTP/internal/raw entry access, shared coordinator. |
| 5 | JWT profile | `bootstrap/security/jwt/AccessTokenProfileTest.java`, `BearerAuthenticationIntegrationTest.java`: every required/forbidden JOSE/claim/length/time case with signed tokens. |
| 6 | JWKS | `bootstrap/security/metadata/TrustedJwksCacheTest.java`, `OidcMetadataClientTest.java`: TLS/redirect/size/time bounds, duplicate kids, replacement, removal, outage/status, refresh herd and age. |
| 7 | Ambiguity | `bootstrap/security/CredentialSelectionIntegrationTest.java`, `scripts/verify-security.ps1`: raw duplicate/coalesced headers/cookies, mixed valid session, stale cookie+bearer through nginx. |
| 8 | Browser OIDC | `bootstrap/security/oidc/OidcLoginIntegrationTest.java`, `frontend/e2e/security.spec.ts`: PKCE/confidential client/state/nonce/azp/replay, credential disposal, exact callback. |
| 9 | Session | `bootstrap/security/session/BoundedSessionStoreTest.java`, `SessionLifecycleIntegrationTest.java`: atomic capacity/prelogin, rotation/fixation, cleanup, idle/absolute/restart. |
| 10 | CSRF | `bootstrap/security/CsrfIntegrationTest.java`: 32-byte token, memory/session binding, rotation, ordering, Origin, bearer exemption and protocol denial, logout. |
| 11 | Origin/proxy | `bootstrap/security/PublicOriginTest.java`, real proxy scenarios in `verify-security.ps1`: unknown Host/forwarding injection, safe redirects, limits and method normalization. |
| 12 | Route matrix | `bootstrap/security/RoutePermissionMatrixIntegrationTest.java`: all 23 operations + protocol paths, GET/HEAD, no/each permission and both mechanisms, unlisted methods/paths/dispatch. |
| 13 | Actuator | `bootstrap/security/ManagementSecurityIntegrationTest.java`: exact anonymous status-only probes, authenticated detailed health, discovery/subpaths denied, IdP outage no new readiness coupling. |
| 14 | Me | `bootstrap/security/api/IdentityControllerIntegrationTest.java`: zero grants, sorted output, no-store, HEAD, no raw claims/credentials. |
| 15 | ACK request | Existing `alerts/adapter/in/web/AlertHistoryControllerTest.java` plus security integration: actor null/value/unknown field denied after auth, reason normalization, resource privacy order. |
| 16 | ACK migration | New `alerts/adapter/out/persistence/AlertAcknowledgementV8MigrationIntegrationTest.java`: empty->V8, populated V7->V8, older full chain->V8, old INSERT default, valid/invalid combinations, Unicode, restart. |
| 17 | Replay/provenance | Existing `alerts/domain/AlertEpisodeAcknowledgementTest.java`, `alerts/application/AcknowledgeAlertEpisodeServiceTest.java`, `H2AlertLifecycleRepositoryTest.java`: all replay rows, frozen legacy display/snapshots. |
| 18 | Concurrency | Existing `alerts/adapter/out/persistence/H2AlertLifecycleRepositoryTest.java`: barrier-controlled ACK-first/RESOLVE-first, competing ACKs, one immutable row; same serialization as baseline. |
| 19 | Manual permission | Existing `alerts/adapter/in/web/AlertLifecycleControllerTest.java` plus authorized wrapper tests: E only succeeds, OPERATOR fails, no implicit R. |
| 20 | Scheduler regression | Existing `alerts/adapter/in/worker/AlertEvaluationSchedulerTest.java`, `alerts/application/SingleFlightAlertLifecycleEvaluationUseCaseTest.java`: credential-free internal path, shared overlap protection, existing queue/cadence/shutdown. |
| 21 | Frontend | New `frontend/src/features/auth/AuthProvider.test.tsx`; extend `App.test.tsx`, `api/client.test.ts`, alert-history/lifecycle tests: bootstrap, permissions, no automatic replay, stale-query/cache isolation, attribution. |
| 22 | Security telemetry | New `selfobservability/adapter/security/SecurityObservationTest.java`: exact counters/dimensions, bounded structured logs, no identity/cardinality, single decision counting. |
| 23 | Leak proof | New `bootstrap/security/CredentialLeakIntegrationTest.java`, browser E2E, `scripts/Test-GeordiCredentialLeaks.ps1`: full channel inventory, positive controls and scanner negative control, failure artifacts. |
| 24 | OpenAPI | Proposed `scripts/validate-openapi.mjs` (pinned test-only validator) and contract assertions in route/DTO tests: 3.1 schema, refs, security OR, permissions/errors, strict ACK, protocol endpoints. |
| 25 | M9–M18 | Full `backend/mvnw verify`, full frontend suite and existing ordered PowerShell chain; no removed persistence/evidence/provider/scheduler/history assertions. |

Freeze compatibility SQL before changing persistence; test legacy actor/reason/timestamp
and existing API projection, then assert only the intended additive attribution change.
Do not serialize updated objects to manufacture supposedly old fixture evidence.

## Exact OpenAPI implementation requirements

Keep OpenAPI 3.1. Define `bearerAuth` type http/scheme bearer/bearerFormat JWT and
`browserSession` type apiKey/in cookie/name `__Host-GEORDISESSION`. Protected operations
use OR, not both in one object:

```yaml
security:
  - bearerAuth: []
  - browserSession: []
```

Document required canonical permission per operation in description or a bounded
extension, never fake OAuth scopes. Me supports either mechanism; csrf/logout specify
browserSession only. Document X-CSRF-TOKEN as required for session mutation, not for
bearer mutation (conditional requirement in description/test contract). Add 400 where
applicable, 401, 403 and bounded 503 plus challenge/no-store/Retry-After headers where
applicable. Preserve existing successful/domain failure responses and ACK 201/200/409.
Add me, csrf, logout (204), identity/permission/provenance schemas and attribution to
ACK response and embedded episode detail. Reason-only request has additionalProperties
false and nullable optional reason; actor presence including null invalid. Explicitly
document GET/HEAD parity for allowed read/me/probe routes; protocol csrf remains GET
only. Server examples use configured same-origin HTTPS, not obsolete localhost HTTP.
No persistence DTO/raw IdP schema. Validate spec against actual route inventory and tests.

## Semantic smoke, fixture reuse and CI budget

Existing job orders telemetry/metrics/traces/logs/service-map/SLO/burn then
`verify-alert-evaluation.ps1`, `verify-alert-lifecycle.ps1`,
`verify-notification-delivery.ps1`, `verify-alert-scheduling.ps1`,
`verify-alert-routing.ps1`, `verify-alert-history.ps1`. M16/M17 and M18 evidence already
live inside the relevant scripts; preserve their assertions, not merely their filenames.

Start TLS/fixture once before backend startup discovery. Run `verify-security.ps1` once
after stack readiness and telemetry positive controls, before the authenticated ordered
regressions. Give it isolated policy/episode fixture identities so it cannot consume
episodes required by later smokes. Restore fixture key/outage controls before regressions.
The M19 smoke proves:

1. Anonymous GET/HEAD liveness/readiness success and status-only; anonymous read 401.
2. VIEWER read success, VIEWER ACK 403; OPERATOR actor request 400 then valid reason-only
   ACK 201, durable issuer/subject/provenance correct, identical replay 200; other
   identity/reason 409; original timestamp/name snapshot retained across backend restart.
3. EVALUATOR manual lifecycle success; OPERATOR without E 403; scheduler still advances
   internally without network credentials and shares lifecycle exclusion behavior.
4. One real browser OIDC code/PKCE/session flow with trusted local CA, me, CSRF bootstrap,
   mutation failure without CSRF, success with CSRF, logout and invalidated session.
5. Invalid JWT signature, wrong audience and ID-token-as-access-token each 401.
6. Mixed/duplicate credentials through real nginx 400; unknown/expired cookie with valid
   bearer succeeds. Proxy/Host and boundary-limit checks have fixed bounded cases.
7. Sentinel inspection with positive controls across all required channels is clean.
8. Complete authenticated M9–M18 chain (and existing preceding telemetry/feature checks),
   provenance validation and cleanup. Final post-chain sentinel/artifact scan also clean.

Shared `GeordiAuthentication.ps1` obtains short-lived fixture tokens via a private
test-only mint/control channel, keeps them in process/private ephemeral storage and
attaches Authorization explicitly. Separate VIEWER/OPERATOR/EVALUATOR identities and
explicit union permission fixture for existing all-capability regression operations;
do not expand OPERATOR. Renew before expiry between operations; never retry a mutation
automatically on auth failure. Pass tokens privately to parallel runspaces, never CLI
arguments/stdout/URLs. Reuse helper/bootstrap across Compose overlay restarts and ensure
each overlay retains security configuration/trust; fail if auth settings disappear.
Do not perform full OIDC login for every script. Do not use unsigned tokens/mock auth
in Compose; backend tests may generate real signed tokens against the test issuer.

Budget: 24m36s historical integration versus 27m script leaves about 2m24s before
script limit, not a proven M19 allowance. The 30m job includes reserved teardown time.
No assumed timeout increase. Add per-stage monotonic timings (fixture/certs/build,
startup, M19, each existing smoke, scan, cleanup) and collect repeated representative
Windows runner measurements. Exhaustive JWT/claim/session/JWKS/permission permutations
belong in backend tests using injected clocks and embedded HTTPS fixture; React state
combinations belong in Vitest. Full Compose is only for nginx serialization/TLS, actual
browser flow, persistence restart, scheduler wiring and agent->Collector->Tempo/log leaks.
Share one fixture/bootstrap and reuse existing ACK restart/provider fault scenarios
where equivalent assertions can be added; preserve each old semantic outcome. Do not
parallelize stateful existing smokes or repeat costly provider-outage scenarios solely
for every role. Bound waits with conditions and explicit deadlines instead of fixed sleeps.

Before CI acceptance compare measured critical path to script and teardown budgets.
If insufficient, remove duplicated setup/scenarios while preserving coverage and measure
again. A timeout change is only a later measured implementation decision documented with
per-stage evidence and the reason coverage cannot fit safely; it is not this plan's fix.
Keep exclusive resource group, candidate checkout/JAR SHA/image labels and cleanup on
every exit. Auth fixture artifacts/private CA material must never enter build artifacts.

## Rollout, rollback and non-goals

Roll out as one coordinated single-node maintenance deployment: isolate ingress, backup
durable storage, validate issuer/audience/mapping/TLS/secret inputs and external IdP
registration, run additive V8, start the complete authenticated build, verify probes and
authenticated reads/mutations and then open supported nginx ingress. Remove direct
public backend exposure; internal container health probes remain exact status-only HTTP
on the private network, not an application authentication bypass. Document operational
sign-in recovery via validated configuration/redeployment, not emergency no-auth routes.

No schema downgrade is required. Pre-M19 binaries may structurally write legacy rows
because additive defaults permit it; that does not make them safe to expose: they remove
authentication. Mixed-version rolling deployment is unsupported. Rollback to pre-M19
requires external network isolation and preservation of upgraded data/backup; retain M18
durable v2 reader compatibility constraints as well. Never downgrade authenticated facts
to actor assertions or backfill legacy identities. Sessions are invalidated by restart.

Non-goals: local users/passwords, registration/reset, MFA implementation, IdP admin or
user directory; tenant/org model, ownership/resource ACL, ABAC, generic policy engine,
generic audit ledger, nonrepudiation/compliance claims; incidents, silences, maintenance
windows, escalation, assignment/comments, routing mutation, delivery redrive/cancel,
runtime policy/SLO CRUD; M20, Spring Boot upgrade, SCA/SBOM remediation, distributed
sessions, and general provider-storage authentication redesign. Do not add microservices
to the production modular monolith; the test IdP is a nonproduction fixture.

## Implementation completion criteria

- Full `backend/mvnw -B -ntp verify` (Windows `mvnw.cmd`) passes all tests, PMD,
  SpotBugs, Find Security Bugs and ArchUnit; record counts and tool reports.
- In frontend, `npm ci`, `npm test`, `npm run typecheck`, `npm run lint`,
  `npm run build`; real browser security E2E through supported TLS ingress passes.
- OpenAPI 3.1 validation, route/security/schema correspondence, every supported Compose
  overlay `config --quiet`, Collector/Tempo/Loki configuration validation and security
  startup validation pass. Migration compatibility and strict attribution checks pass.
- M19 semantic smoke and entire authenticated M9–M18 ordered regression chain pass,
  with verified source/JAR/image provenance, bounded runtime, successful cleanup and
  positive-controlled sentinel scan including artifacts/failure diagnostics.
- Reproducible local/CI trust and startup instructions, health/metrics/traces/structured
  logs, synchronized product/architecture/ACK/history/API/operations docs and ADR-022.
- Fresh independent implementation reviewer checks final code/diff and evidence;
  resolve findings and rerun affected gates. Planning review is not implementation proof.
  Mark M19 complete only after all acceptance evidence exists; stop at requested scope.

## Independent planning review record

The configured `reviewer` agent was requested but could not start: its fixed `gpt-5.6`
model is unavailable. As explicitly authorized, a fresh separate `gpt-6-astra` agent
performed the independent read-only fallback review against the full owner request,
this plan and relevant baseline code. The earlier repository-evidence agent was not
used as reviewer. No agent modified any repository file.

Initial findings: **BLOCKER 0 / HIGH 0 / MEDIUM 1 / LOW 0**. The MEDIUM finding was
a circular slice acceptance gate: Slice 7 required a complete route matrix before
ACK/protocol endpoints existed in Slices 8–9. Remediation gives Slice 7 provisional
implemented-route/denied-deferred-route acceptance and assigns the complete matrix to
Slice 9, with explicit dependencies on 6–8. Early foundation-test references are also
distinguished from later full integration gates. Independent remediation re-review
confirmed the fix and found **BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0** unresolved.
Accepted planning debt: none. Implementation still requires its own fresh final review.

Planning validation: complete new-file diff inspected; `git diff --check` and
`git diff --no-index --check -- /dev/null docs/plans/MILESTONE-019.md` produce no
whitespace diagnostics (the latter also checks this untracked file). HEAD, main and
origin/main remain the authoritative baseline. Final `git status --short` contains only:

```text
?? docs/plans/MILESTONE-019.md
```

No implementation/build/runtime tests were run for this planning-only change. No
production code, tests, frontend, OpenAPI, Compose, CI, V8 or ADR-022 were modified or
created. No commit or push was performed.

M19 PLANNED — READY FOR IMPLEMENTATION
