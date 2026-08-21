import { lazy, Suspense } from 'react'
import { Navigate, Route, Routes } from 'react-router-dom'
import { PlatformOverview } from './features/platform-overview/PlatformOverview'
import { AppShell } from './components/AppShell'
import { ServiceMetricsPage } from './features/service-metrics/ServiceMetricsPage'
import { TraceDetailPage } from './features/traces/TraceDetailPage'
import { TraceSearchPage } from './features/traces/TraceSearchPage'
import { ServiceInvestigationPage } from './features/service-investigation/ServiceInvestigationPage'
import { LogsPage } from './features/logs/LogsPage'
import { SloPage } from './features/slos/SloPage'

const ServiceMapPage = lazy(async () => {
  const module = await import('./features/service-map/ServiceMapPage')
  return { default: module.ServiceMapPage }
})

export function App() {
  return (
    <AppShell>
      <Routes>
        <Route path="/" element={<PlatformOverview />} />
        <Route path="/metrics" element={<ServiceMetricsPage />} />
        <Route path="/traces" element={<TraceSearchPage />} />
        <Route path="/traces/:traceId" element={<TraceDetailPage />} />
        <Route path="/logs" element={<LogsPage />} />
        <Route path="/investigate" element={<ServiceInvestigationPage />} />
        <Route path="/service-map" element={<Suspense fallback={<main className="state-panel" aria-busy="true">Loading Service Map…</main>}><ServiceMapPage /></Suspense>} />
        <Route path="/slos" element={<SloPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </AppShell>
  )
}
