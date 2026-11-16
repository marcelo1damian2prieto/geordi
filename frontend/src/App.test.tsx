import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider, useQuery } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { App } from './App'

const authFixture = vi.hoisted(() => ({
  identity: { issuer: 'https://identity.example', subject: 'operator', displayName: 'Operator', permissions: ['observability:read'], authMode: 'SESSION' },
}))

vi.mock('./api/auth', () => ({
  getCurrentIdentity: () => Promise.resolve(authFixture.identity),
  logout: () => Promise.resolve(undefined),
}))

function renderRoute(path: string) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const rendered = render(<QueryClientProvider client={queryClient}><MemoryRouter initialEntries={[path]}><App /></MemoryRouter></QueryClientProvider>)
  return { ...rendered, queryClient }
}

afterEach(() => {
  authFixture.identity = { issuer: 'https://identity.example', subject: 'operator', displayName: 'Operator', permissions: ['observability:read'], authMode: 'SESSION' }
})

vi.mock('./features/alert-history/AlertHistoryPage', () => ({
  AlertHistoryPage: () => <main>Alert history route</main>,
}))

vi.mock('./features/platform-overview/PlatformOverview', () => ({
  PlatformOverview: () => {
    const query = useQuery({ queryKey: ['principal-view'], queryFn: () => Promise.resolve(authFixture.identity.subject) })
    return <main>Platform overview route: {query.data ?? 'loading'}</main>
  },
}))

vi.mock('./features/service-metrics/ServiceMetricsPage', () => ({
  ServiceMetricsPage: () => <main>Service metrics route</main>,
}))

vi.mock('./features/traces/TraceSearchPage', () => ({
  TraceSearchPage: () => <main>Trace search route</main>,
}))

vi.mock('./features/traces/TraceDetailPage', () => ({
  TraceDetailPage: () => <main>Trace detail route</main>,
}))

vi.mock('./features/service-investigation/ServiceInvestigationPage', () => ({
  ServiceInvestigationPage: () => <main>Service investigation route</main>,
}))

vi.mock('./features/logs/LogsPage', () => ({
  LogsPage: () => <main>Logs route</main>,
}))

vi.mock('./features/service-map/ServiceMapPage', () => ({
  ServiceMapPage: () => <main>Service map route</main>,
}))

vi.mock('./features/slos/SloPage', () => ({
  SloPage: () => <main>SLOs route</main>,
}))

vi.mock('./features/alert-lifecycle/AlertLifecyclePage', () => ({
  AlertLifecyclePage: () => <main>Alert lifecycle route</main>,
}))

describe('application routes', () => {
  it('renders the history bookmark and shell navigation', async () => {
    renderRoute('/alert-history?episodeId=' + 'a'.repeat(64))
    expect(await screen.findByText('Alert history route')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Alert history' })).toHaveAttribute('href', '/alert-history')
  })
  it('unmounts protected views after successful logout', async () => {
    renderRoute('/alert-history')
    expect(await screen.findByText('Alert history route')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Sign out' }))

    expect(await screen.findByRole('heading', { name: 'Signed out' })).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByText('Alert history route')).not.toBeInTheDocument())
    expect(screen.queryByRole('button', { name: 'Sign out' })).not.toBeInTheDocument()
  })
  it('clears and remounts principal-scoped views when the session changes', async () => {
    const { queryClient } = renderRoute('/')
    expect(await screen.findByText(/Platform overview route: operator/)).toBeInTheDocument()

    authFixture.identity = {
      ...authFixture.identity,
      subject: 'operator-b',
      displayName: 'Operator B',
    }
    window.dispatchEvent(new Event('geordi:auth-invalidated'))

    expect(await screen.findByText(/Platform overview route: operator-b/)).toBeInTheDocument()
    expect(screen.queryByText(/Platform overview route: operator$/)).not.toBeInTheDocument()
    expect(queryClient.getQueryData(['principal-view'])).toBe('operator-b')
  })
  it('renders service metrics at its public route', async () => {
    renderRoute('/metrics')

    expect(await screen.findByText('Service metrics route')).toBeInTheDocument()
    expect(screen.queryByText('Platform overview route')).not.toBeInTheDocument()
  })

  it('redirects unknown routes to the platform overview', async () => {
    renderRoute('/not-a-route')

    expect(await screen.findByText(/Platform overview route/)).toBeInTheDocument()
  })

  it('does not mount read views for a signed-in principal without read permission', async () => {
    authFixture.identity = { ...authFixture.identity, permissions: ['alerts:evaluate'] }
    renderRoute('/alert-evaluations')

    expect(await screen.findByRole('heading', { name: 'Read permission required' })).toBeInTheDocument()
    expect(screen.queryByText('Alert lifecycle route')).not.toBeInTheDocument()
  })

  it('renders trace search and trace detail at their public routes', async () => {
    const { unmount } = renderRoute('/traces')
    expect(await screen.findByText('Trace search route')).toBeInTheDocument()

    unmount()
    renderRoute('/traces/aabb')
    expect(await screen.findByText('Trace detail route')).toBeInTheDocument()
  })

  it('renders service investigation at its public route', async () => {
    renderRoute('/investigate')

    expect(await screen.findByText('Service investigation route')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Investigate' })).toBeInTheDocument()
  })

  it('renders logs at its public route', async () => {
    renderRoute('/logs')

    expect(await screen.findByText('Logs route')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Logs' })).toBeInTheDocument()
  })

  it('lazy-loads Service Map at its public route', async () => {
    renderRoute('/service-map?environment=development')

    expect(await screen.findByText('Service map route')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Service map' })).toBeInTheDocument()
  })

  it('renders SLOs at its public route', async () => {
    renderRoute('/slos')

    expect(await screen.findByText('SLOs route')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'SLOs' })).toBeInTheDocument()
  })

  it('renders alert lifecycle at the compatible public route', async () => {
    renderRoute('/alert-evaluations')

    expect(await screen.findByText('Alert lifecycle route')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Alert lifecycle' })).toBeInTheDocument()
  })
})
