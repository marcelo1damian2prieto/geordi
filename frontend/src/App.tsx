import { Navigate, Route, Routes } from 'react-router-dom'
import { PlatformOverview } from './features/platform-overview/PlatformOverview'
import { AppShell } from './components/AppShell'
import { ServiceMetricsPage } from './features/service-metrics/ServiceMetricsPage'

export function App() {
  return (
    <AppShell>
      <Routes>
        <Route path="/" element={<PlatformOverview />} />
        <Route path="/metrics" element={<ServiceMetricsPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </AppShell>
  )
}
