# Geordi frontend

React application for the Geordi platform overview, Metrics and Traces vertical slices,
and the lightweight `/investigate` workflow. Service Investigation composes both signal
APIs with one canonical service identity and absolute range, isolates partial failures,
and returns from Trace Detail without losing context.
The UI intentionally does not expose backend query languages, arbitrary dashboards,
or a generic visualization engine.

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
