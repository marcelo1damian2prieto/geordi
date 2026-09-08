# Milestone 015 — Alert History Investigation UI

Status: M15 COMPLETE

Planning baseline: 2026-09-07. M15 is complete. The approved scope remains unchanged.

## Authoritative GitLab closure

M15 closed on the authoritative implementation commit
`1971fa1c35a4b661e13d793bf3a3962e99160005` (`feat(alerts): add alert history
investigation UI`). All authoritative GitLab pipeline jobs were green:
`backend`, `deployment_configuration`, `frontend`, and `local_stack_smoke`.

`local_stack_smoke` checked out that commit from `main`; verified that the backend
artifact revision equalled `CI_COMMIT_SHA` and verified its SHA-256 provenance; built
and exercised the current frontend; passed the existing semantic regression chain;
executed the extended Alert History smoke; and verified real M14 episode list/detail
behavior through the deployed frontend/API proxy. It verified exact canonical evidence
and timestamp preservation, schema/privacy restrictions, RFC9457 invalid-range
responses, and the M14 durability/restart/routing-independence assertions. Cleanup
completed and the job ended `Job succeeded`.

This closure confirms the actual M15 scope only: the read-only `/alert-history` UI,
bounded URL-anchored history investigation, episode detail/bookmarks, and
persisted-evidence Investigation links. Alert Lifecycle remains authoritative for
current FIRING state. M15 introduces no backend domain/schema/write-path change and no
M16 scope.

## Implementation execution record

- Reconfirmed existing frontend client/types/context, routing, query-provider and nginx
  seams against the M14 OpenAPI contract. No production backend or API change needed.
- Ownership: frontend feature/navigation and RED-first tests; independent page-test
  worker; existing M14 smoke extension in its script only; documentation and closure
  gates coordinated separately. A fresh read-only reviewer follows local verification.
- Backend `./mvnw.cmd -B -ntp verify`: PASS, 289 tests, no failures/errors/skips,
  including ArchUnit, PMD, SpotBugs and Find Security Bugs.
- Base and M10/M12/M13/M14 Compose configuration checks: PASS.
- Frontend `npm ci`, full tests (210 tests across 26 files), typecheck, lint and
  production build: PASS. New history coverage: 5 API, 35 URL, 5 presentation and
  31 page cases, plus App and Lifecycle navigation regressions. Production build
  retains the existing large-chunk advisory; no dependency/bundle redesign is included.
- OTel Collector, Tempo and Loki configuration validation: PASS. Verified backend
  runtime image, supporting images and frontend image built without cache; fresh
  Compose startup passed. The exact semantic chain and independent review passed.
- Local baseline revision: `481685111da7746a524390576b1c4014a673198d` plus the M15
  working diff. Backend is unchanged. Verified JAR SHA-256:
  `800ffd92ce022803c0ac00d4406b79d6a832ee1550ec8cb46f7aa1aac5c8c20d`;
  runtime image labels match the revision and digest. This is local provenance,
  not a claim of a GitLab-tested implementation commit.
- Toolchain: Node 24.15.0, npm 11.12.1, Java 26.0.1 (Java 21 target),
  PowerShell 7.6.5, Docker Engine 29.7.2. Local logs are in `backend/target/m15-*`.
- Observed RED runs preceded API, page, presentation and navigation implementation;
  focused GREEN runs and the complete suite followed. The page race tests resolve B
  before A with abort-ignoring fetch doubles for list and detail, and show B only.
  Calendar/range tests prove exact 31 days valid and +1 ns invalid; API/context tests
  and exact `<time>` text preserve canonical timestamp strings and nulls.
- Accessibility coverage proves labeled/described controls, invalid/error summaries,
  semantic caption/column headers, keyboard selection and `aria-current`, one-time
  detail-heading focus, close focus restoration/fallback and Back/Forward without
  focus stealing. Whitelisted rendering and GET-only endpoint assertions exclude
  writes, evaluation calls, transition searches and arbitrary private payload fields.
- Applied skills: `investigate-first`, `surgical-patch` principles, `verify-and-stop`,
  `caveman-review` for the upcoming independent review. Subagent implementation work
  was interrupted by an account usage limit; primary agent completed the remaining
  implementation and verification. No implementation agent will serve as reviewer.
- The ordered OTel → Metrics → Traces → Logs → Service Map → SLO → Burn Rate
  (provider failure/recovery) → Alert Evaluation → Lifecycle → Notification Delivery
  → Scheduling → Routing semantic gates passed. Initial History proxy validation
  exposed PowerShell byte-array Content for a charset-free Problem response. A focused
  RED reproduced the conversion error; decoding UTF-8 before string-date parsing
  passed GREEN for both string and byte JSON, preserving nine fractional digits.
  The corrected History smoke passed with explicit transition-ID parity. The correction
  is confined to the approved smoke script.
- Fresh read-only final review: **BLOCKER 0 · HIGH 0 · MEDIUM 0 · LOW 0**. It checked
  the full tracked/untracked implementation against the authoritative plan, including
  scope, precision, URL validation, query-key isolation, current/history and legacy
  semantics, investigation context, privacy, accessibility, smoke evidence and M16
  exclusion. The reviewer accepted the supplied gate evidence and did not rerun tests.

## Objective and boundary

Expose durable M14 episode list/detail through a bounded, bookmarkable `/alert-history`
operator workflow. The page is read-only. Alert Lifecycle at `/alert-evaluations`
remains authoritative for current FIRING state. History means **“episodes opened in
this window”**, never “all currently open alerts”. OPEN filters only the episodes
opened in the selected window that remain unresolved in the history projection.

Affected implementation areas: frontend Alerts history feature, existing application
navigation, existing M14 integration smoke, and documentation. No backend production
code, domain rule, persistence behavior, Flyway migration, API contract, write path,
routing, delivery, scheduling, or lifecycle behavior changes. No new runtime component
or telemetry pipeline is required; existing health and telemetry remain applicable.

ADR decision: no new ADR. ADR-019 already establishes the durable read boundary,
legacy origin, authority, privacy, and retention. Adding a frontend consumer does not
change those decisions. M14's “no UI” describes its milestone scope, not a prohibition
on this approved subsequent milestone.

## Repository evidence and reuse

All paths below are repository-relative. Existing files are reuse seams, not blanket
permission to refactor them.

| Existing seam | Reuse / implication |
| --- | --- |
| `frontend/src/App.tsx`, `components/AppShell.tsx`, `App.test.tsx` | Add route and shell link using current Routes/Link patterns. Current lifecycle route is `/alert-evaluations`, not `/alert-lifecycle`. |
| `frontend/src/features/alert-lifecycle/AlertLifecyclePage.tsx`, its test | Add a history link; preserve current evaluation actions and current-state semantics. |
| `frontend/src/api/client.ts`, `client.test.ts` | Reuse `getJson`, `ApiError`, `ProblemDetails`, AbortSignal, configured API base URL, and RFC 9457 parsing. No second HTTP client. |
| `frontend/src/api/alertLifecycles.ts`, `alertEvaluations.ts` | Reuse lifecycle/transition enums and `AlertEvaluation`/`AlertEvidence` types; do not call evaluation endpoints from History. |
| `frontend/src/api/telemetryContext.ts`, its test | Reuse `ServiceIdentity`, `TimeRange`, `contextSearchParams`, `parseTelemetryContext`; preserve nullable namespace. Its six-hour bound is for Investigation, not History's 31 days. |
| `frontend/src/features/logs/logSearchParams.ts`, its test | Follow explicit valid/invalid parser results and URLSearchParams conventions, with a history-local parser. |
| `frontend/src/features/alert-lifecycle/useAlertLifecycles.ts` | Follow `useQuery` with queryFn AbortSignal; do not reuse mutations or lifecycle cache keys. |
| `frontend/src/features/service-investigation/ServiceInvestigationPage.tsx`, its test | Existing `/investigate` consumer, independent signal states and canonical URL context; no destination feature redesign. |
| `frontend/src/features/alert-evaluations/alertEvaluationPresentation.ts` | Reuse safe condition, status, window, and burn-rate formatting. |
| `frontend/src/main.tsx` | Existing QueryClientProvider/BrowserRouter; defaults retry once and no focus refetch. Do not add a provider/store. |
| `frontend/src/styles.css`, `src/test/setup.ts`, `vite.config.ts`, `package.json` | Existing state-panel, controls, tables, focus styles; Vitest/jsdom, Testing Library/user-event/jest-dom. No browser framework installed. |
| `frontend/nginx.conf`, `frontend/vite.config.ts` | nginx forwards `/api/` to backend and falls back to index.html for routes; Vite supports development proxying. No new proxy location expected. |
| `docs/api/openapi.yaml` | `AlertEpisodes`, `AlertEpisode`, `AlertEpisodeDetail`, `AlertTransitionHistory`, `AlertEvaluation`, and existing Problem contract are sufficient. |
| `backend/.../alerts/adapter/in/web/AlertHistoryController.java`, `AlertHistoryExceptionHandler.java` | Actual response names/nullability and 400/404/503 behavior; inspection only. |
| `backend/.../alerts/adapter/out/persistence/H2AlertLifecycleRepository.java` | `appendEpisodeFilters` filters ranges on opened_at even with policy scope; lists order by COALESCE(opened_at,closed_at) DESC then episode_id DESC. Detail transitions order by occurred_at DESC then transition_id DESC. |
| `scripts/verify-alert-history.ps1`, `compose.yaml`, `compose.m14.yaml`, `.gitlab-ci.yml` | Reuse isolated M14 data and existing ordered smoke/provenance chain. |

## Frontend API and query architecture

Add `frontend/src/api/alertHistory.ts` with colocated request/response types and:

- `listAlertEpisodes(query, signal?)`: GET `/api/alert-episodes`, URLSearchParams
  encoding of required M15 `from`, `to`, `limit`, optional `policyId`, `state`.
- `getAlertEpisode(episodeId, signal?)`: GET `/api/alert-episodes/{encodedId}`.
- `AlertEpisodeState = 'OPEN' | 'CLOSED'`; origin `M14 | PRE_M14_UNKNOWN_START`.
  Episode fields: `id`, `policyId`, `openedAt: string | null`,
  `closedAt: string | null`, `origin`, `durationSeconds: number | null`.
- List envelope `{ alertEpisodes: AlertEpisode[] }`; detail envelope
  `{ episode: AlertEpisode; transitions: AlertTransitionHistory[] }`.
  Transition fields: `id`, `episodeId`, `policyId`, existing `AlertTransitionType`,
  `previousState`, `currentState`, `occurredAt`, existing `AlertEvaluation`.
  State is derived from closedAt; do not invent a response `state` field.

Keep RFC3339 timestamps as strings in API data, requests, URLs, and keys. Never
round-trip server evidence through Date/toISOString: M14 preserves nanoseconds.
Use Date only for optional human display, with exact UTC text available in `<time>`
and its dateTime attribute. Use backend-derived durationSeconds (whole elapsed
seconds), not browser-rounded timestamp subtraction or an ongoing completion timer.
No frontend re-evaluation or extra policy catalog dependency is necessary: policyId
is a labeled free-text filter and persisted evaluation supplies historical context.

`frontend/src/features/alert-history/useAlertHistory.ts` owns two hooks:

```text
useAlertEpisodes(validQuery)
key = ['alert-history', 'episodes', from, to, policyId ?? null, state ?? null, limit]

useAlertEpisode(selectedEpisodeId)
key = ['alert-history', 'episode', selectedEpisodeId ?? null]
```

List queries are enabled only after valid absolute URL initialization. Detail queries
require a valid full URL and selected ID; detail is deliberately independent of list
membership/range, matching the API. Thus filters belong in the list key, selected ID
in the detail key. No placeholderData/keepPreviousData, component-owned response
copies, or shared mutable selected-detail cache. Pass queryFn signal to getJson.
Cancellation saves work; keyed observers are the correctness boundary even if a
transport ignores abort. An old filter/detail response can only populate its own key.
Render only the active key, and unmount old detail immediately on selection change.
Cached data for the same key may refetch; label refreshing or failed refresh explicitly.
No polling. Explicit Refresh refetches the active list/detail without changing time.
Override retry only to avoid retrying 400/404; retain one automatic retry for transient
network/5xx failures and offer a bounded manual Retry for the failed region.

## Canonical URL contract

Add `alertHistorySearchParams.ts` under the new feature, following the existing small
parser/serializer pattern. URL is the sole applied filter/selection state; form drafts
may be local until Apply. Use labeled UTC text fields to preserve submillisecond input.

| Parameter | Contract |
| --- | --- |
| `from`, `to` | Paired absolute RFC3339 UTC `Z` instants, inclusive/exclusive respectively; 0 < range <= 31 × 24 hours. Required on every M15 list request, including policy-filtered requests. |
| `policyId` | Optional nonblank exact policy ID. Blank form input removes it; present blank URL value is invalid. No lookup against today's catalog. |
| `state` | Omitted for All, otherwise exactly `OPEN` or `CLOSED`. |
| `limit` | Integer 1–100; omitted means 50. Generated URLs explicitly write 50 by default. No pagination, totals, or export implied. |
| `episodeId` | Optional selected detail ID, exactly 64 lowercase hexadecimal characters. Serialized for bookmark/back navigation; never sent as a list filter. |

Default: when both bounds are absent and other recognized parameters are valid, capture
one clock instant, derive `[now - 24h, now)`, and write both bounds with replace navigation
before enabling requests. This also applies to a direct episode bookmark without bounds.
Guard initialization against StrictMode effect repetition; do not recalculate per render.
Reload and Refresh retain the exact anchored strings. An explicit “Last 24 hours” action
creates a fresh pair using one clock sample; label it as changing the range.

Choose **A: explicit validation error** for invalid bookmark state. Never silently repair
partial, blank, malformed, reversed, excessive, duplicated recognized parameters, invalid
state/limit/ID, or invalid calendar dates. A history-local RFC3339 validator must validate
calendar components and up to nine fractional digits, not rely on permissive Date.parse
alone; compare second-plus-nanosecond values for range order and 31-day boundary.
The M15 URL accepts UTC Z (offset/non-UTC bookmark input gets an explanatory validation
error); API client serialization preserves supplied instants without conversion.
Unsupported fractional precision is explicit invalid input, never rounded.
Unknown parameters are ignored and omitted by generated canonical URLs.
Show editable fields, a validation message and explicit Reset to last 24 hours; dispatch
no list/detail request until corrected. Reset clears invalid filter/selection values.

Apply commits one atomic URL update and clears episodeId; selecting/closing detail
pushes a URL update preserving list filters. Browser Back/Forward restores applied
filters and selection. Default initialization alone uses replace. A direct selected
episode remains visible even outside the listed range/policy/state/limit: say “Selected
episode detail is independent of these list filters.” Do not claim an absent row means
missing history. Selection need not trigger list refetch because its list key is unchanged.

## Operator presentation and component boundaries

Use three components, with small inline filter/presentation sections rather than a new
component framework:

- `AlertHistoryPage.tsx`: URL/apply/reset/refresh coordination, labeled filter form,
  list status and current-state explanation; compose list and optional detail.
- `AlertEpisodeList.tsx`: semantic table, policy/id, origin/status, opened/resolved
  timestamps and duration; each episode has a real Link with an accessible name.
- `AlertEpisodeDetail.tsx`: heading, canonical episode fields, bounded transitions,
  evidence links, retention notice, and independent loading/error/retry.
- `alertHistoryPresentation.ts`: pure duration/origin/transition labels and persisted
  evidence link construction. No component just for duration or one anchor.

Normal OPEN: text “OPEN — ongoing”, exact opened timestamp, resolved “Not resolved”,
duration “Unavailable while ongoing”; never show completed duration or imply current
telemetry was reevaluated. Normal CLOSED: “CLOSED”, opened/resolved timestamps and
the derived completed duration. PRE_M14_UNKNOWN_START: “CLOSED — legacy, start unknown”,
“Start unavailable”, “Duration unavailable”, real resolved timestamp, no invented start.

Important actual M14 constraint: policy scope alone can return legacy rows, but adding
a range excludes NULL opened_at. M15 always supplies a range, so legacy episodes are
supported through direct episodeId detail bookmarks, not claimed discoverable in this
bounded list. Explain this limitation beside the list. Do not add a second unbounded
policy history request, resolution-based membership, or synthetic legacy list row.
A legacy list renderer case may be tested defensively with a unit fixture, explicitly
not presented as proof the ranged backend query returns that row. Legacy discovery
beyond known IDs is deferred and is not a blocker for the approved bounded workflow.

Preserve API list ordering, including ID tie-breaks, instead of sorting timestamp
strings or millisecond Dates. Detail preserves deterministic newest-first API order
and labels that order. Display canonical STARTED / RESOLVED labels mapped from actual
wire values ALERT_STARTED / ALERT_RESOLVED; include occurredAt and previous/current
state. Whitelist canonical policy, condition/status and evidence identity/window/range,
evaluatedAt, observed burn rate. Never render arbitrary JSON or routing/destination,
delivery, endpoint, secret, provider payload, or notification fields.
Show “Showing up to N episodes; narrow the filters” when at the limit; no invented total.

## Service Investigation and retention

Each persisted transition with usable `evaluation.evidence` gets its own “Investigate
STARTED evidence” or “Investigate RESOLVED evidence” link. This makes the source of the
range unambiguous and handles differing start/resolve context without combining them.

```text
evidence = transition.evaluation.evidence
params = contextSearchParams(evidence.service, evidence.range)
href = '/investigate?' + params.toString()
```

Use `service.name` → serviceName, non-null `service.namespace` → serviceNamespace,
`service.environment` → environment, `evidence.range.from/to` → from/to verbatim.
Check compatibility with `parseTelemetryContext` before enabling the link, and ensure
parsed identity equals the original (no trimming/substitution). Its existing maximum
is six hours; M14 SLO windows PT5M/PT15M/PT1H/PT6H fit. Missing or invalid evidence,
or a context the existing destination rejects, gives “Investigation unavailable for
this persisted evidence” while history remains readable. Do not widen destination
limits, use History's 24-hour interval, substitute now, or call current policy evaluation.

There is no authoritative retention-availability metadata in the history response.
Always show a non-blocking notice with historical detail: “Alert history can outlive
source telemetry retention. Metrics, traces, or logs for this evidence window may no
longer be available.” This covers likely-expired evidence without inventing a retention
threshold or asserting deletion. Keep valid links enabled. Missing source telemetry
does not make history corrupt. Do not add provider probes or a retention settings API.

## Validation, errors, and accessibility

| Condition | Bounded UX |
| --- | --- |
| Invalid timestamp/partial pair/from >= to/>31 days/enum/limit/ID | Local explicit validation with preserved URL and editable controls; no request. |
| Backend 400 Problem | “Invalid alert history request”; keep filters available; no automatic retry. |
| List 404 (capability route absent) | “Alert history is unavailable or disabled”; not an empty history assertion. |
| Detail 404 | “Episode not found or history unavailable”; distinguish from list empty, preserve list and allow close/change selection. Do not assume deletion. |
| 503, network, malformed/non-Problem failure | Bounded unavailable message and Retry for affected region; never echo raw response/exception body. |
| Initial loading / refetch | Accessible loading / refreshing state for active key; no prior-selection placeholder. |
| Empty successful list | “No episodes opened in this window match these filters”; preserve filters and lifecycle link. |
| Failed same-key refresh with cached data | Explicitly label cached results and failed refresh, never silently present them as refreshed. |

Reuse ApiError/Problem parsing, map HTTP status to safe copy rather than depending on
arbitrary Problem detail text. List and detail failures do not remove the other's valid
content. Form fields use labels, instructions and aria-describedby; invalid fields
use aria-invalid and a role=alert summary. Filters use native input/select/button.
Table has caption, headings with scope, and real keyboard-accessible selection links;
selected link uses aria-current. Status/origin distinctions always have text.
Detail is a labeled section, not a modal. Explicit selection focuses its stable
tabIndex=-1 heading after the URL commit (heading exists while loading); loading
completion does not steal focus again. Closing detail returns focus to its initiating
link if still present, otherwise the list heading. Bookmark/back navigation must not
unexpectedly steal focus. Use polite role=status announcements for loading/result count
and role=alert for errors; avoid repeatedly announcing the entire table. Retain visible
focus and existing accessible state-panel styles. No new accessibility dependency.

## RED-first test matrix

Write failing acceptance tests before each corresponding behavior; the focused-test
step later consolidates coverage, it is not permission to defer RED until after coding.
Use Vitest/jsdom and Testing Library with a fresh QueryClient (retry disabled in tests),
MemoryRouter/route location probe, user-event and controlled/deferred fetch responses.

| Layer / proposed file | Required proof |
| --- | --- |
| `api/alertHistory.test.ts` | GET-only list/detail; query/path encoding including policy punctuation; null fields/envelopes; UTC/nanosecond preservation; AbortSignal; existing Problem parsing via ApiError, malformed/non-Problem fallback. |
| `features/alert-history/alertHistorySearchParams.test.ts` | Absent/valid/invalid distinction, strict calendar/precision, duplicates, partial pair, equal/reversed, exact 31 days and +1ns, state, limit 0/101/noninteger, episode ID, canonical round trip. |
| `features/alert-history/alertHistoryPresentation.test.ts` | Normal open/no duration, closed derived whole seconds including zero, legacy unknown start/duration, explicit wire-label mapping, exact namespaced/null-namespace identity/range link, incompatible/null evidence, no now substitution. |
| `features/alert-history/AlertHistoryPage.test.tsx` | Single default 24h pair written before request under StrictMode; reload and Refresh anchored with advanced clock; explicit Last 24h reset; policy/OPEN/CLOSED/limit apply; list and tie ordering; limit notice; selected/detail outside filters; transitions newest-first; retention notice even for old evidence; loading/empty/400/404/503/network/retry; local invalid URL blocks fetch; all status/origin presentations. |
| Same page tests, async cases | Deferred A then B list: resolve B then A and assert B only. Deferred detail A then B, including abort-ignoring mock: A cannot replace B. Invalid URL/cleared selection disables old detail. Same-key refresh failure is labeled. |
| Same page tests, accessibility | Labels/roles/caption, keyboard selection, heading focus once, close focus fallback, non-color labels, announcements, retry accessible names. Assert no History-triggered POST or transition-list/evaluation call. |
| `frontend/src/App.test.tsx`, `features/alert-lifecycle/AlertLifecyclePage.test.tsx` | Direct /alert-history bookmark, shell link, lifecycle → history with policyId, default anchor, selected bookmark, MemoryRouter Back/Forward restores range/filter/detail; existing routes/actions unchanged. |

Test detail with a legacy response from the real schema and document that no ranged
list can discover it. No separate deployed history-data fixture. Small mocked response
objects in frontend tests are UI examples, not a replacement semantic fixture. No
Playwright/Cypress or claimed real-browser coverage from jsdom.

## Smallest semantic smoke extension

Modify only `scripts/verify-alert-history.ps1` for integration behavior. Add
`FrontendBaseUrl = 'http://127.0.0.1:3000'`. Include `frontend` in its existing M14
startup/force-recreate list and wait for the frontend/API path to be ready within the
existing deadline. Recreating frontend after backend replacement avoids nginx retaining
the old backend container address. Reuse compose.yaml + compose.m14.yaml and their
dedicated reset/cleanup protections; no compose.m15 or second fixture.

After the existing STARTED and RESOLVED facts are captured, but before offline H2
inspection stops the backend, issue GETs through FrontendBaseUrl `/api/alert-episodes`
with an absolute bounded range containing the fixture's actual openedAt and policyId,
and `/api/alert-episodes/{episodeId}`. Derive enclosing bounds from the fixture timestamps
with outward padding (not lossy conversion of the expected canonical timestamp).
Assert the expected episode is present, same ID/policy/openedAt/closedAt/origin/duration,
and both detail transitions link to that episode and match the captured canonical
type/state/occurredAt/service namespace/name/environment/evidence bounds. Compare exact
timestamp strings, using PowerShell JSON string-date handling (`-DateKind String` when
supported, otherwise System.Text.Json) so conversion cannot erase precision.

Through the same proxy assert invalid equal/reversed range returns HTTP 400,
application/problem+json, and bounded RFC9457 fields/status rather than HTML.
Check list and detail against schema-shaped allowed field sets and absence of known
fixture token values, destination URLs/IDs, routing/delivery fields and raw payload.
Never print secrets on assertion failure. Keep all existing M14 retry/restart,
H2 durability, routing independence and telemetry assertions.

An HTTP GET of `/alert-history?...` can check SPA fallback/HTML availability only;
if included, label it exactly that. It does not execute React or validate rendered UI.
Evidence layers: component tests prove UI semantics; deployed proxy smoke proves
nginx/API integration using real M14 data; existing backend tests/smoke prove durable
history semantics. No new legacy database fixture is needed for M15.

## CI, documentation and proposed file inventory

CI: no new job or dependency expected. Existing frontend job already runs tests,
typecheck, lint and build. Existing local_stack_smoke builds frontend before running
the M9–M14 chain, with M14 last at 480 seconds; the extended script runs in that slot.
Preserve backend verify, verified-artifact revision/SHA256 and runtime-image labels,
deployment_configuration, smoke order, resource lock, timeouts and cleanup. Change
`.gitlab-ci.yml` only if implementation proves invocation wiring is needed (the default
FrontendBaseUrl should avoid it); do not weaken gates to fit the new assertions.

New production frontend files: `frontend/src/api/alertHistory.ts` and
`frontend/src/features/alert-history/{alertHistorySearchParams.ts,useAlertHistory.ts,
AlertHistoryPage.tsx,AlertEpisodeList.tsx,AlertEpisodeDetail.tsx,alertHistoryPresentation.ts}`.
New tests: the four files named in the matrix. Modified existing frontend files:
`src/App.tsx`, `src/components/AppShell.tsx`, `src/App.test.tsx`,
`src/features/alert-lifecycle/AlertLifecyclePage.tsx` and its test;
`src/styles.css` only for necessary scoped layout/focus styles.
Existing API client, canonical context helper, package files, nginx and backend are
reuse/verification targets; no modifications are anticipated.

Implementation documentation updates:

- `README.md`: route, anchored semantics, read-only workflow, startup and extended smoke.
- `frontend/README.md`: feature/test conventions and navigation.
- `docs/plans/MILESTONE-015.md`: implementation evidence and authoritative closure.
- `docs/product/PRD.md`, `docs/product/ROADMAP.md`: bounded capability and actual status.
- `docs/architecture/ARCHITECTURE.md`, `docs/architecture/ALERT_LIFECYCLE.md`:
  frontend composition and current-state/history distinction, legacy access limitation.
- `docs/architecture/SERVICE_INVESTIGATION.md`: persisted per-transition links and
  retention caveat; existing canonical contract unchanged.
- `docs/api/openapi.yaml`: metadata/description only if useful to explain the UI
  consumer; no path/schema/semantics changes. M14 and ADR-019 historical scope remains intact.

## Ordered implementation sequence

| Step | Work and likely files |
| --- | --- |
| 1 | RED API tests, then types/client in `api/alertHistory.ts` + test. |
| 2 | RED URL tests, then history-local parsing/serialization in `alertHistorySearchParams.ts` + test. |
| 3 | Keyed GET hooks in `useAlertHistory.ts`; prove disabled/abort/stale behavior with page harness. |
| 4 | `AlertHistoryPage.tsx` skeleton, App route/shell navigation and routing tests. |
| 5 | Inline filters and `AlertEpisodeList.tsx`; anchored apply/reset, ordering and selection tests. |
| 6 | `AlertEpisodeDetail.tsx`; independent detail/bookmark/error and transition tests. |
| 7 | `alertHistoryPresentation.ts` duration/origin/legacy rules and focused tests. |
| 8 | Persisted Investigation links and tests; lifecycle history link in existing page/test. |
| 9 | Loading/error/empty/retention/focus behavior and minimal styles; corresponding tests first. |
| 10 | Complete matrix, deferred-response races, route/back/accessibility and no-write assertions. |
| 11 | Extend `scripts/verify-alert-history.ps1` on existing M14 fixture and proxy. |
| 12 | Update only relevant docs listed above with implemented facts. |
| 13 | Run full local closure gates below against final code/artifacts. |
| 14 | Fresh independent review; fix BLOCKER/HIGH, rerun affected gates, verify final diff, then GitLab revalidation. |

## Closure gates and evidence record

The following gates define the closure evidence. The authoritative GitLab result above
confirms the applicable final implementation/artifact validation; this retained list
documents the reproducible gate design rather than pending work.

1. Frontend directory: `npm ci`, `npm test`, `npm run typecheck`, `npm run lint`,
   `npm run build` with supported Node >=22.12.
2. Backend directory: existing authoritative `./mvnw -B -ntp verify` (Windows
   `.\mvnw.cmd -B -ntp verify`) unchanged, including JUnit, ArchUnit, PMD, SpotBugs,
   Find Security Bugs. Preserve final-artifact provenance for runtime smoke.
3. Root: `docker compose config --quiet` and
   `docker compose --file compose.yaml --file compose.m14.yaml config --quiet`;
   preserve existing M10/M12/M13 configuration checks. Build the verified backend
   runtime and current frontend as in the existing CI recipe before smoke.
4. Run the existing regression chain in order with fixture credentials/prerequisites
   from current README/CI: `verify-alert-evaluation.ps1 -TimeoutSeconds 150`,
   `verify-alert-lifecycle.ps1 -TimeoutSeconds 240`,
   `verify-notification-delivery.ps1 -TimeoutSeconds 300`,
   `verify-alert-scheduling.ps1 -TimeoutSeconds 300`,
   `verify-alert-routing.ps1 -TimeoutSeconds 360`, then
   `pwsh -File ./scripts/verify-alert-history.ps1 -TimeoutSeconds 480` (M14/M15 combined).
   Scripts reside in `scripts/` and run under pwsh. Preserve earlier existing stack
   smokes for OTel, metrics, traces, logs, service-map, SLO and burn-rate in CI.
5. `git diff --check`, review changed files for accidental backend/contract/scope drift.
6. Independent reviewer: BLOCKER 0, HIGH 0; record/reconcile all MEDIUM/LOW findings.
   Record tested commit, tool versions, commands/results and artifact identity. Document
   reproducible startup (`docker compose up -d --build`, existing configuration prerequisites,
   then frontend port 3000 `/alert-history`) and do not substitute mock tests for proxy proof.

The authoritative GitLab pipeline passed against the final implementation commit
`1971fa1c35a4b661e13d793bf3a3962e99160005`; therefore **M15 COMPLETE**. Compilation
alone would not have been closure.

## Explicit non-goals

No acknowledgement, comments, assignment, incidents, silences, maintenance windows,
routing changes, notification history UI, runtime CRUD, retention deletion, episode
mutation, generic timeline/chart builder, generic transition explorer, new datastore,
new auth/RBAC design, browser E2E framework, or M16. No speculative abstractions,
dependencies, backend aggregation, unbounded policy-history mode or current-state
replacement. Useful out-of-scope findings are recorded, not implemented.

## Plan review and owner decisions

Independent read-only plan review completed 2026-09-07 by a fresh supported-model
reviewer agent. The configured reviewer could not start because its configured model
was unavailable; the explicitly permitted supported-model fallback was used.
**BLOCKER 0 · HIGH 0 · MEDIUM 0 · LOW 0.** No actionable findings required reconciliation.
The review checked the attached requirements against ADR-019, the actual M14
controller/query/persistence contracts, frontend context/client/proxy seams, smoke and
CI. It challenged frontend-only scope, anchored URLs and precision, current-state
authority, stale responses, legacy access, evidence/retention honesty, proportional
smoke coverage and M16 exclusion. This is plan review, not runtime validation.

Planning verification: only this new document changed; tracked production files remain
unchanged. `git diff --check` and the new-file `git diff --no-index --check` passed.
No frontend/backend build or smoke was run for this documentation-only task; those
remain the implementation closure gates above. Skills applied selectively:
`investigate-first`, `caveman-review`, `verify-and-stop`.

No owner decision is required for the bounded plan. The ranged API's inability to
discover unknown-start legacy episodes is explicitly retained; known-ID detail is
supported. Expanding legacy discovery would require separately approved scope rather
than silently changing M14 semantics or introducing a second query mode in M15.
