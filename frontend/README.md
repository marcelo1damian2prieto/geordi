# Geordi frontend

React application for the Geordi platform overview and bounded Metrics, Traces, and
Logs vertical slices, the lightweight `/investigate` workflow, the trace-derived
`/service-map` workflow, the completed Milestones 7–8 `/slos` foundation, and the
completed M9 Alert Evaluation and M10 Alert Lifecycle experience at
`/alert-evaluations`. M11 Notification Delivery is complete but backend/operational
only and adds no frontend route. Service Investigation composes all three signal APIs
with one
canonical service identity and
absolute range, isolates partial failures, and returns from Trace Detail without losing
context. Trace Detail opens related Logs only when valid carried context is available.
Service Map is a bounded observed-dependency view for one exact environment and range;
it reuses Investigation and Trace Detail navigation rather than duplicating them. The
UI intentionally does not expose backend query languages, arbitrary dashboards, or a
generic visualization engine. Its ECharts graph code is route-lazy-loaded with
`/service-map` so it does not enlarge the initial application route bundle.

`/slos` lists the deployment-managed read-only catalog and issues one on-demand
evaluation query per enabled definition. It presents textual `MET`, `BREACHED`, and
`UNAVAILABLE` states, ratios as percentages, fixed windows, request evidence, and
bounded unavailable reasons. Disabled definitions are shown without a query. Evaluation
query keys include every definition identity/semantic field, and Investigation links use
the evaluation response's exact service identity and absolute range. The catalog limit
of 50 bounds the current per-row query fan-out.

`/alert-evaluations` is the implemented alert route for both milestones. M9 contributes
the canonical condition result—`CONDITION_MET`, `CONDITION_NOT_MET`, or `UNAVAILABLE`—
with its bounded reason and exact evidence. M10 adds current `INACTIVE`/`FIRING`
lifecycle state, an explicit “Evaluate now” command, and nullable
`ALERT_STARTED`/`ALERT_RESOLVED` transition presentation. The page keeps condition
evaluation, lifecycle state, and transition as separate concepts. Investigation
navigation uses only the canonical service identity and exact evidence range, including
retained firing evidence when the latest evaluation is unavailable.

The corresponding implemented API routes remain distinct: M9's side-effect-free
`GET /api/alert-policies/{policyId}/evaluation`, M10's explicit state-changing
`POST /api/alert-policies/{policyId}/lifecycle-evaluations`, and M10's read-only
`GET /api/alert-states`. The current page reads lifecycle snapshots and renders the
nested/latest M9 condition evidence without presenting it as lifecycle state.

The frontend has no scheduler, notification-delivery status or management UI, incident,
acknowledgement, silencing, or related management UI. M11 webhook delivery remains a
backend/operational capability. A transition is not presented as a delivered
notification or incident event.

## M15 Alert History

Status: **COMPLETE**. The authoritative GitLab pipeline validated commit
`1971fa1c35a4b661e13d793bf3a3962e99160005`, including the extended Alert History
smoke through the deployed frontend/API proxy. Closure evidence is recorded in
`../docs/plans/MILESTONE-015.md`.

`/alert-history` is a read-only M14 episode consumer, reachable from the shell and
Alert Lifecycle. It lists episodes opened in an anchored absolute UTC range: initially
24 hours, at most 31 days. Reload and Refresh preserve that URL interval; Last 24 hours
explicitly creates another. Exact policy ID, OPEN/CLOSED and limit (1–100, default 50)
are URL filters. Invalid or incomplete URLs block requests and expose editable validation.
OPEN describes unresolved episodes opened in the window; `/alert-evaluations` remains
the current-state authority.

Episode selection is stored in the URL and detail remains independent of list filters.
The API's unknown-start legacy episodes are accessible through a known-ID bookmark,
not discoverable by this ranged list. API ordering, exact timestamp strings and
server-derived completed duration are preserved. Ongoing and legacy unknown duration
remain explicitly unavailable.

Per-transition Investigation links use persisted service identity and evidence bounds,
validated against the unchanged six-hour canonical context limit. Missing/incompatible
evidence disables only its link. A retention notice explains that source telemetry may
have expired while durable history remains readable. History sends GETs only and adds
no evaluation, delivery or routing actions.

History uses the existing API client, React Router and TanStack Query provider. List
keys contain all applied filters; detail keys contain the selected ID. Abort signals,
independent loading/error/retry states, explicit cached-refresh failure labels and no
previous-selection placeholders protect the active URL context. No polling or new store
is introduced.

Colocated API/parser/presentation/page tests use Vitest, jsdom and Testing Library for
URL precision, navigation, stale responses, keyboard/focus behavior and safe errors.
These are component tests, not browser E2E. The existing M14 smoke extension validates
real episode/evidence responses through nginx; SPA HTML availability alone does not
prove React rendering.

## Development startup

Prerequisites: Node.js >=22.12 and a backend listening on `http://localhost:8080`.

```powershell
npm ci
npm run dev
```

Open `http://localhost:5173`. Vite proxies `/api` to `http://localhost:8080` by
default. Set `GEORDI_BACKEND_URL` when the backend uses a different development URL.
Open `/alert-history` on that origin for the History workflow. For the full local stack,
follow the root README's `.env` prerequisites and run `docker compose up -d --build`
from the repository root, then open `http://127.0.0.1:3000/alert-history`.

For a production build, `VITE_API_BASE_URL` can prefix API requests. Its default is
empty, so requests remain same-origin and the included nginx configuration proxies
`/api` to the Docker hostname `backend:8080`.

## Quality gates

```powershell
npm run test
npm run typecheck
npm run lint
npm run build
```

## Container image

```powershell
docker build -t geordi-frontend:local .
docker run --rm -p 127.0.0.1:3000:8080 geordi-frontend:local
```

The container expects to share a Docker network with a backend service named
`backend`. The SPA is served on container port `8080`.
