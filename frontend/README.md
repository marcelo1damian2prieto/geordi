# Geordi frontend

React application for the Geordi platform overview and Milestone 2 service metrics
vertical slice. The fixed service-operations view discovers monitored services and
shows HTTP and JVM metrics for 15-minute, 1-hour, or 6-hour ranges. It intentionally
does not expose arbitrary metrics queries or dashboard editing.

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
