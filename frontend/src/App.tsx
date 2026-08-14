import { Navigate, Route, Routes } from 'react-router-dom'
import { PlatformOverview } from './features/platform-overview/PlatformOverview'
import { AppShell } from './components/AppShell'
import { ServiceMetricsPage } from './features/service-metrics/ServiceMetricsPage'
import { TraceDetailPage } from './features/traces/TraceDetailPage'
import { TraceSearchPage } from './features/traces/TraceSearchPage'
import { ServiceInvestigationPage } from './features/service-investigation/ServiceInvestigationPage'
import { LogsPage } from './features/logs/LogsPage'

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
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </AppShell>
  )
}
