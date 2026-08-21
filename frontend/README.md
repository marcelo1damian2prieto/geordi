# Geordi frontend

React application for the Geordi platform overview and bounded Metrics, Traces, and
Logs vertical slices, the lightweight `/investigate` workflow, the trace-derived
`/service-map` workflow, and the completed Milestone 7 `/slos` foundation. Service
Investigation composes all three signal APIs with one canonical service identity and
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
