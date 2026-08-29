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

## Local development

Prerequisites: Node.js 22 and a backend listening on `http://localhost:8080`.

```powershell
npm ci
npm run dev
```

Open `http://localhost:5173`. Vite proxies `/api` to `http://localhost:8080` by
default. Set `GEORDI_BACKEND_URL` when the backend uses a different development URL.

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
