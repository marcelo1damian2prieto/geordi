import { Navigate, Route, Routes } from 'react-router-dom'
import { PlatformOverview } from './features/platform-overview/PlatformOverview'

export function App() {
  return (
    <Routes>
      <Route path="/" element={<PlatformOverview />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  )
}
