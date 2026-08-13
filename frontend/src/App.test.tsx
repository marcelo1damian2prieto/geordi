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
})
