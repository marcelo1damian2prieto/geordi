import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { MetricSeriesResponse, ServiceIdentity } from '../../api/metrics'
import type { TraceSearchResponse } from '../../api/traces'
import type { LogSearchResponse } from '../../api/logs'
import { ServiceInvestigationPage } from './ServiceInvestigationPage'

vi.mock('../service-metrics/MetricChart', () => ({
  MetricChart: ({ title }: { title: string }) => <div role="img" aria-label={`${title} time series`} />,
}))

const service = { name: 'checkout', namespace: 'store', environment: 'local' } satisfies ServiceIdentity
const range = { from: '2026-08-13T14:45:00.000Z', to: '2026-08-13T15:00:00.000Z' }
const entry = `/investigate?serviceName=checkout&serviceNamespace=store&environment=local&from=${encodeURIComponent(range.from)}&to=${encodeURIComponent(range.to)}`
const metricSeries = {
  service, range,
  series: [
    { metric: 'HTTP_REQUEST_RATE', unit: '{request}/s', points: [{ timestamp: range.to, value: 0 }] },
    { metric: 'HTTP_REQUEST_COUNT', unit: '{request}', points: [{ timestamp: range.to, value: 20 }] },
    { metric: 'HTTP_REQUEST_LATENCY_P95', unit: 's', points: [{ timestamp: range.to, value: 0.125 }] },
    { metric: 'JVM_MEMORY_USED', unit: 'By', points: [{ timestamp: range.to, value: 1048576 }] },
  ],
} satisfies MetricSeriesResponse
const recent = {
  service, range,
  traces: [
    { traceId: 'a'.repeat(32), rootSpanName: 'GET /recent', startTime: '2026-08-13T14:59:00Z', durationNanos: 125_000_000, spanCount: 3, error: false },
    { traceId: 'b'.repeat(32), rootSpanName: 'GET /slow', startTime: '2026-08-13T14:58:00Z', durationNanos: 800_000_000, spanCount: 4, error: false },
  ],
} satisfies TraceSearchResponse
const errors = {
  service, range,
  traces: [{ traceId: 'c'.repeat(32), rootSpanName: 'POST /error', startTime: '2026-08-13T14:57:00Z', durationNanos: 250_000_000, spanCount: 2, error: true }],
} satisfies TraceSearchResponse
const logResult = {
  service,
  range,
  logs: [{
    timestamp: '2026-08-13T14:56:00.000Z',
    observedTimestamp: '2026-08-13T14:56:00.010Z',
    severity: 'WARN',
    severityText: 'WARN',
    body: 'Inventory reservation is slow',
    service,
    traceId: 'd'.repeat(32),
    spanId: 'e'.repeat(16),
    attributes: { 'event.name': 'inventory.reservation.slow' },
  }],
} satisfies LogSearchResponse

function response(body: unknown, status = 200) {
  return Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }))
}

function urlOf(input: RequestInfo | URL) {
  return new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
}

function renderPage(initialEntry = entry) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[initialEntry]}><ServiceInvestigationPage /></MemoryRouter>
    </QueryClientProvider>,
  )
}

function mockSuccess() {
  return vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
    const url = urlOf(input)
    if (url.pathname === '/api/metrics/services' || url.pathname === '/api/traces/services' || url.pathname === '/api/logs/services') {
      return response({ services: [service] })
    }
    if (url.pathname === '/api/metrics/series') {
      const requestedMetrics = new Set(url.searchParams.getAll('metric'))
      return response({ ...metricSeries, series: metricSeries.series.filter((series) => requestedMetrics.has(series.metric)) })
    }
    if (url.pathname === '/api/traces') return response(url.searchParams.get('errorOnly') === 'true' ? errors : recent)
    if (url.pathname === '/api/logs') return response(logResult)
    throw new Error(`Unexpected request: ${url.pathname}`)
  })
}

beforeEach(() => vi.setSystemTime(new Date(range.to)))
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks() })

describe('Service investigation', () => {
  it('uses one exact canonical context for RED, JVM, trace, and log evidence', async () => {
    const fetchMock = mockSuccess()
    renderPage()

    expect(await screen.findByRole('heading', { name: 'Service investigation' })).toBeInTheDocument()
    expect(screen.getByRole('combobox', { name: 'Service and environment' })).toHaveDisplayValue('store / checkout · local')
    expect(await screen.findByText('0.00 req/s')).toBeInTheDocument()
    expect(screen.getByText('20 requests in selected range')).toBeInTheDocument()
    expect(screen.getByText('1.0 MiB')).toBeInTheDocument()
    expect(screen.getAllByText('GET /recent').length).toBeGreaterThan(0)
    expect(screen.getAllByText('GET /slow').length).toBeGreaterThan(0)
    expect(screen.getByText('POST /error')).toBeInTheDocument()
    expect(screen.getByText('Inventory reservation is slow')).toBeInTheDocument()
    expect(screen.getByText('Trace linked')).toBeInTheDocument()

    const evidence = fetchMock.mock.calls.map(([input]) => urlOf(input)).filter((url) =>
      url.pathname === '/api/metrics/series' || url.pathname === '/api/traces' || url.pathname === '/api/logs',
    )
    expect(evidence).toHaveLength(5)
    evidence.forEach((url) => {
      expect(url.searchParams.get('serviceName')).toBe('checkout')
      expect(url.searchParams.get('serviceNamespace')).toBe('store')
      expect(url.searchParams.get('environment')).toBe('local')
      expect(url.searchParams.get('from')).toBe(range.from)
      expect(url.searchParams.get('to')).toBe(range.to)
    })
    const metricCalls = evidence.filter((url) => url.pathname === '/api/metrics/series')
    expect(metricCalls.map((url) => url.searchParams.getAll('metric').length).sort()).toEqual([4, 5])
    expect(evidence.filter((url) => url.searchParams.get('errorOnly') === 'true')).toHaveLength(1)
    expect(evidence.filter((url) => url.pathname === '/api/logs')).toHaveLength(1)
    expect(evidence.find((url) => url.pathname === '/api/logs')?.searchParams.get('limit')).toBe('5')
  })

  it('keeps Metrics visible when Traces fails and Traces visible when Metrics fails', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname.endsWith('/services')) return response({ services: [service] })
      if (url.pathname === '/api/metrics/series') return response(metricSeries)
      if (url.pathname === '/api/traces') return response({}, 503)
      if (url.pathname === '/api/logs') return response(logResult)
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    const first = renderPage()
    expect(await screen.findByText('0.00 req/s')).toBeInTheDocument()
    expect((await screen.findAllByRole('alert')).some((node) => node.textContent?.includes('Trace storage is unavailable.'))).toBe(true)
    first.unmount()
    vi.restoreAllMocks()

    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname.endsWith('/services')) return response({ services: [service] })
      if (url.pathname === '/api/metrics/series') return response({}, 503)
      if (url.pathname === '/api/traces') return response(url.searchParams.get('errorOnly') === 'true' ? errors : recent)
      if (url.pathname === '/api/logs') return response(logResult)
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage()
    expect(await screen.findByText('POST /error')).toBeInTheDocument()
    expect(screen.getByText('Inventory reservation is slow')).toBeInTheDocument()
    expect((await screen.findAllByRole('alert')).some((node) => node.textContent?.includes('Metrics storage is unavailable.'))).toBe(true)
  })

  it('keeps Metrics and Traces visible when recent Logs fails', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname.endsWith('/services')) return response({ services: [service] })
      if (url.pathname === '/api/metrics/series') return response(metricSeries)
      if (url.pathname === '/api/traces') return response(url.searchParams.get('errorOnly') === 'true' ? errors : recent)
      if (url.pathname === '/api/logs') return response({}, 503)
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage()

    expect(await screen.findByText('20 requests in selected range')).toBeInTheDocument()
    expect(screen.getByText('POST /error')).toBeInTheDocument()
    expect((await screen.findAllByRole('alert')).some((node) => node.textContent?.includes('Log storage is unavailable.'))).toBe(true)
    expect(screen.getByRole('link', { name: 'View all logs' })).toHaveAttribute('href', expect.stringContaining('serviceNamespace=store'))
  })

  it('isolates JVM failure from RED and error-trace failure from recent traces', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname.endsWith('/services')) return response({ services: [service] })
      if (url.pathname === '/api/metrics/series') {
        return url.searchParams.has('metric', 'JVM_MEMORY_USED') ? response({}, 503) : response(metricSeries)
      }
      if (url.pathname === '/api/traces') return url.searchParams.get('errorOnly') === 'true' ? response({}, 503) : response(recent)
      if (url.pathname === '/api/logs') return response(logResult)
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage()

    expect(await screen.findByText('0.00 req/s')).toBeInTheDocument()
    expect(screen.getAllByText('GET /recent').length).toBeGreaterThan(0)
    const alerts = await screen.findAllByRole('alert')
    expect(alerts.some((node) => node.textContent?.includes('Metrics storage is unavailable.'))).toBe(true)
    expect(alerts.some((node) => node.textContent?.includes('Trace storage is unavailable.'))).toBe(true)
  })

  it('keeps context controls and section-specific failures when both providers fail', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname.endsWith('/services')) return response({ services: [service] })
      if (url.pathname === '/api/metrics/series' || url.pathname === '/api/traces') return response({}, 503)
      if (url.pathname === '/api/logs') return response(logResult)
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage()

    expect(await screen.findByRole('combobox', { name: 'Service and environment' })).toHaveDisplayValue('store / checkout · local')
    expect(screen.getByRole('group', { name: 'Time range' })).toBeInTheDocument()
    expect(await screen.findAllByRole('alert')).toHaveLength(4)
  })

  it('treats missing telemetry as absent while preserving returned zero', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname.endsWith('/services')) return response({ services: [service] })
      if (url.pathname === '/api/metrics/series') {
        const metrics = url.searchParams.getAll('metric')
        return response(metrics.includes('HTTP_REQUEST_RATE') ? { ...metricSeries, series: metricSeries.series.slice(0, 1) } : { ...metricSeries, series: [] })
      }
      if (url.pathname === '/api/traces') return response({ ...recent, traces: [] })
      if (url.pathname === '/api/logs') return response(logResult)
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage()

    expect(await screen.findByText('0.00 req/s')).toBeInTheDocument()
    expect(screen.getAllByText('No telemetry in this range.').length).toBeGreaterThan(0)
    expect(screen.getByText('No recent traces in this range.')).toBeInTheDocument()
    expect(screen.getByText('No error traces in this range.')).toBeInTheDocument()
  })

  it('opens trace detail with full context and an enumerated investigation origin', async () => {
    mockSuccess()
    renderPage()

    const links = await screen.findAllByRole('link', { name: 'Open trace' })
    const target = new URL(links[0].getAttribute('href')!, 'http://geordi.test')
    expect(target.pathname).toMatch(/^\/traces\/[0-9a-f]{32}$/)
    expect(target.searchParams.get('origin')).toBe('investigate')
    expect(target.searchParams.get('serviceNamespace')).toBe('store')
    expect(target.searchParams.get('from')).toBe(range.from)
    expect(target.searchParams.get('to')).toBe(range.to)
  })

  it('never presents the previous identity while a new service is loading', async () => {
    const second = { name: 'checkout', namespace: null, environment: 'staging' } satisfies ServiceIdentity
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname.endsWith('/services')) return response({ services: [service, second] })
      if (url.searchParams.get('environment') === 'staging') return new Promise<Response>(() => undefined)
      if (url.pathname === '/api/metrics/series') return response(metricSeries)
      if (url.pathname === '/api/traces') return response(url.searchParams.get('errorOnly') === 'true' ? errors : recent)
      if (url.pathname === '/api/logs') return response({ ...logResult, service: second })
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage()
    const selector = await screen.findByRole('combobox', { name: 'Service and environment' })
    expect(await screen.findByText('20 requests in selected range')).toBeInTheDocument()
    expect(screen.getByText('POST /error')).toBeInTheDocument()

    await userEvent.selectOptions(selector, '[null,"checkout","staging"]')

    expect(await screen.findByText('Loading RED metrics…')).toBeInTheDocument()
    expect(screen.getByText('Loading recent traces…')).toBeInTheDocument()
    expect(screen.queryByText('20 requests in selected range')).not.toBeInTheDocument()
    expect(screen.queryByText('POST /error')).not.toBeInTheDocument()
  })

  it('rejects malformed bookmarks without issuing telemetry requests', () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
    renderPage('/investigate?serviceName=checkout')

    expect(screen.getByRole('heading', { name: 'Invalid investigation context' })).toBeInTheDocument()
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('discovers the exact union when no context is supplied and tolerates one discovery failure', async () => {
    const traceOnly = { name: 'inventory', namespace: null, environment: 'local' } satisfies ServiceIdentity
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname === '/api/metrics/services') return response({}, 503)
      if (url.pathname === '/api/traces/services') return response({ services: [traceOnly] })
      if (url.pathname === '/api/logs/services') return response({ services: [] })
      if (url.pathname === '/api/metrics/series') return response({ ...metricSeries, service: traceOnly, series: [] })
      if (url.pathname === '/api/traces') return response({ ...recent, service: traceOnly, traces: [] })
      if (url.pathname === '/api/logs') return response({ ...logResult, service: traceOnly })
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage('/investigate')

    expect(await screen.findByRole('combobox', { name: 'Service and environment' })).toHaveDisplayValue('inventory · local')
    expect(screen.getByText(/Metrics storage is unavailable during service discovery/)).toBeInTheDocument()
  })

  it('does not report telemetry absence when bare-route discovery fails', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname.endsWith('/services')) return response({}, 503)
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage('/investigate')

    expect(await screen.findByRole('heading', { name: 'Service discovery unavailable' })).toBeInTheDocument()
    expect(screen.getAllByRole('alert')).toHaveLength(3)
    expect(screen.queryByRole('heading', { name: 'No monitored services found' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Retry discovery' })).toBeInTheDocument()
  })

  it('keeps the absolute range fixed on refresh and replaces it atomically for a preset', async () => {
    const fetchMock = mockSuccess()
    renderPage()
    await screen.findByRole('heading', { name: 'Service investigation' })

    await userEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    await waitFor(() => expect(fetchMock.mock.calls.length).toBeGreaterThanOrEqual(12))
    const refreshed = fetchMock.mock.calls.map(([input]) => urlOf(input)).filter((url) => url.pathname === '/api/traces')
    expect(refreshed.every((url) => url.searchParams.get('from') === range.from && url.searchParams.get('to') === range.to)).toBe(true)

    vi.setSystemTime(new Date('2026-08-13T16:00:00.000Z'))
    await userEvent.click(screen.getByRole('button', { name: '1h' }))
    await waitFor(() => {
      const updated = fetchMock.mock.calls.map(([input]) => urlOf(input)).filter((url) => url.searchParams.get('to') === '2026-08-13T16:00:00.000Z')
      expect(updated.length).toBeGreaterThanOrEqual(4)
      updated.forEach((url) => expect(url.searchParams.get('from')).toBe('2026-08-13T15:00:00.000Z'))
    })
  })

  it('removes prior-range evidence immediately while the new absolute range loads', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname.endsWith('/services')) return response({ services: [service] })
      if (url.searchParams.get('to') === '2026-08-13T16:00:00.000Z') return new Promise<Response>(() => undefined)
      if (url.pathname === '/api/metrics/series') return response(metricSeries)
      if (url.pathname === '/api/traces') return response(url.searchParams.get('errorOnly') === 'true' ? errors : recent)
      if (url.pathname === '/api/logs') return response(logResult)
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage()
    expect(await screen.findByText('20 requests in selected range')).toBeInTheDocument()

    vi.setSystemTime(new Date('2026-08-13T16:00:00.000Z'))
    await userEvent.click(screen.getByRole('button', { name: '1h' }))

    expect(await screen.findByText('Loading RED metrics…')).toBeInTheDocument()
    expect(screen.queryByText('20 requests in selected range')).not.toBeInTheDocument()
    expect(screen.queryByText('POST /error')).not.toBeInTheDocument()
  })
})
