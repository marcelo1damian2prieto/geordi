import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it, vi } from 'vitest'
import { App } from './App'

vi.mock('./features/platform-overview/PlatformOverview', () => ({
  PlatformOverview: () => <main>Platform overview route</main>,
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

describe('application routes', () => {
  it('renders service metrics at its public route', () => {
    render(<MemoryRouter initialEntries={['/metrics']}><App /></MemoryRouter>)

    expect(screen.getByText('Service metrics route')).toBeInTheDocument()
    expect(screen.queryByText('Platform overview route')).not.toBeInTheDocument()
  })

  it('redirects unknown routes to the platform overview', async () => {
    render(<MemoryRouter initialEntries={['/not-a-route']}><App /></MemoryRouter>)

    expect(await screen.findByText('Platform overview route')).toBeInTheDocument()
  })

  it('renders trace search and trace detail at their public routes', () => {
    const { unmount } = render(<MemoryRouter initialEntries={['/traces']}><App /></MemoryRouter>)
    expect(screen.getByText('Trace search route')).toBeInTheDocument()

    unmount()
    render(<MemoryRouter initialEntries={['/traces/aabb']}><App /></MemoryRouter>)
    expect(screen.getByText('Trace detail route')).toBeInTheDocument()
  })

  it('renders service investigation at its public route', () => {
    render(<MemoryRouter initialEntries={['/investigate']}><App /></MemoryRouter>)

    expect(screen.getByText('Service investigation route')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Investigate' })).toBeInTheDocument()
  })

  it('renders logs at its public route', () => {
    render(<MemoryRouter initialEntries={['/logs']}><App /></MemoryRouter>)

    expect(screen.getByText('Logs route')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Logs' })).toBeInTheDocument()
  })

  it('lazy-loads Service Map at its public route', async () => {
    render(<MemoryRouter initialEntries={['/service-map?environment=development']}><App /></MemoryRouter>)

    expect(await screen.findByText('Service map route')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Service map' })).toBeInTheDocument()
  })
})
