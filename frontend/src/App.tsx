import { lazy, Suspense, useEffect, useState } from 'react'
import { Navigate, Route, Routes } from 'react-router-dom'
import { useQuery, useQueryClient } from '@tanstack/react-query'
import { PlatformOverview } from './features/platform-overview/PlatformOverview'
import { AppShell } from './components/AppShell'
import { ServiceMetricsPage } from './features/service-metrics/ServiceMetricsPage'
import { TraceDetailPage } from './features/traces/TraceDetailPage'
import { TraceSearchPage } from './features/traces/TraceSearchPage'
import { ServiceInvestigationPage } from './features/service-investigation/ServiceInvestigationPage'
import { LogsPage } from './features/logs/LogsPage'
import { SloPage } from './features/slos/SloPage'
import { AlertLifecyclePage } from './features/alert-lifecycle/AlertLifecyclePage'
import { AlertHistoryPage } from './features/alert-history/AlertHistoryPage'
import { ApiError, markAuthenticationValidated } from './api/client'
import { getCurrentIdentity } from './api/auth'
import { AuthProvider } from './features/auth/AuthProvider'

const ServiceMapPage = lazy(async () => {
  const module = await import('./features/service-map/ServiceMapPage')
  return { default: module.ServiceMapPage }
})

export function App() {
  const [signedOut, setSignedOut] = useState(false)
  const [identityStale, setIdentityStale] = useState(false)
  const [boundIdentityKey, setBoundIdentityKey] = useState<string>()
  const queryClient = useQueryClient()
  const identity = useQuery({
    queryKey: ['auth', 'me'],
    queryFn: ({ signal }) => getCurrentIdentity(signal),
    retry: false,
    refetchOnWindowFocus: true,
  })

  useEffect(() => {
    const revalidate = () => {
      setIdentityStale(true)
      void (async () => {
        await queryClient.cancelQueries()
        await queryClient.refetchQueries({ queryKey: ['auth', 'me'], exact: true })
        queryClient.removeQueries({ predicate: query => query.queryKey[0] !== 'auth' })
        setIdentityStale(false)
      })()
    }
    window.addEventListener('geordi:auth-invalidated', revalidate)
    return () => window.removeEventListener('geordi:auth-invalidated', revalidate)
  }, [queryClient])

  useEffect(() => {
    if (!identity.data) return
    const identityKey = `${identity.data.issuer}\n${identity.data.subject}\n${identity.data.authMode}`
    const principalChanged = boundIdentityKey !== undefined && boundIdentityKey !== identityKey
    const bindIdentity = () => {
      markAuthenticationValidated(principalChanged)
      setBoundIdentityKey(identityKey)
      setIdentityStale(false)
    }
    if (principalChanged) {
      void queryClient.cancelQueries().then(() => {
        queryClient.removeQueries({ predicate: query => query.queryKey[0] !== 'auth' })
        bindIdentity()
      })
      return
    }
    bindIdentity()
  }, [identity.data, identity.dataUpdatedAt, boundIdentityKey, queryClient])

  if (signedOut) return <main className="state-panel"><h1>Signed out</h1><p>Your Geordi session has ended.</p><a href="/oauth2/authorization/geordi">Sign in</a></main>
  if (identityStale) return <main className="state-panel" role="status">Checking your Geordi session…</main>
  if (identity.isPending) return <main className="state-panel" role="status">Checking your Geordi session…</main>
  if (identity.isError && identity.error instanceof ApiError && identity.error.status === 401) {
    return <main className="state-panel"><h1>Sign in to Geordi</h1><p>Use your organization account to continue.</p><a href="/oauth2/authorization/geordi">Sign in</a></main>
  }
  if (identity.isError) {
    return <main className="state-panel" role="alert"><h1>Geordi is unavailable</h1><p>Your session could not be checked.</p><button type="button" onClick={() => void identity.refetch()}>Retry</button></main>
  }
  const identityKey = `${identity.data.issuer}\n${identity.data.subject}\n${identity.data.authMode}`
  if (boundIdentityKey !== identityKey) return <main className="state-panel" role="status">Checking your Geordi session…</main>
  if (!identity.data.permissions.includes('observability:read')) {
    return <main className="state-panel"><h1>Read permission required</h1><p>Your account is signed in but cannot read Geordi observability data.</p></main>
  }

  return (
    <AuthProvider key={identityKey} permissions={new Set(identity.data.permissions)}>
    <AppShell identity={identity.data} onSignedOut={() => setSignedOut(true)}>
      <Routes>
        <Route path="/" element={<PlatformOverview />} />
        <Route path="/metrics" element={<ServiceMetricsPage />} />
        <Route path="/traces" element={<TraceSearchPage />} />
        <Route path="/traces/:traceId" element={<TraceDetailPage />} />
        <Route path="/logs" element={<LogsPage />} />
        <Route path="/investigate" element={<ServiceInvestigationPage />} />
        <Route path="/service-map" element={<Suspense fallback={<main className="state-panel" aria-busy="true">Loading Service Map…</main>}><ServiceMapPage /></Suspense>} />
        <Route path="/slos" element={<SloPage />} />
        <Route path="/alert-evaluations" element={<AlertLifecyclePage />} />
        <Route path="/alert-history" element={<AlertHistoryPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </AppShell>
    </AuthProvider>
  )
}
