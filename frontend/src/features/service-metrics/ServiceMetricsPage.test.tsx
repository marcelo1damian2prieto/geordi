import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { App } from '../../App'

vi.mock('./MetricChart', () => ({
  MetricChart: ({ title }: { title: string }) => <div role="img" aria-label={`${title} time series`} />,
}))

const service = { name: 'checkout', namespace: 'store', environment: 'local' }
const overview = {
  service,
  range: { from: '2026-08-13T14:45:00.000Z', to: '2026-08-13T15:00:00.000Z' },
  values: [
    { metric: 'HTTP_REQUEST_RATE', unit: '{request}/s', value: 0, timestamp: '2026-08-13T15:00:00Z' },
    { metric: 'HTTP_REQUEST_COUNT', unit: '{request}', value: 20, timestamp: '2026-08-13T15:00:00Z' },
    { metric: 'JVM_MEMORY_USED', unit: 'By', value: 1048576, timestamp: '2026-08-13T15:00:00Z' },
  ],
}
const series = {
  service,
  range: overview.range,
  series: [{ metric: 'HTTP_REQUEST_RATE', unit: '{request}/s', points: [{ timestamp: '2026-08-13T15:00:00Z', value: 0 }] }],
}

function response(body: unknown, status = 200) {
  return Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }))
}

function renderMetrics() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={['/metrics']}><App /></MemoryRouter>
    </QueryClientProvider>,
  )
}

function mockMetricsApi() {
  return vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
    if (url.pathname.endsWith('/services')) return response({ services: [service] })
    if (url.pathname.endsWith('/overview')) return response(overview)
    return response(series)
  })
}

beforeEach(() => vi.setSystemTime(new Date('2026-08-13T15:00:00.000Z')))
afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
})

describe('Service metrics', () => {
  it('renders a fixed operational view, including valid zero values and partial telemetry', async () => {
    const fetchMock = mockMetricsApi()
    renderMetrics()

    expect(screen.getByText('Discovering monitored services…')).toBeInTheDocument()
    expect(await screen.findByRole('heading', { name: 'Metrics' })).toBeInTheDocument()
    expect(screen.getByRole('combobox', { name: 'Service' })).toHaveDisplayValue('store / checkout · local')
    expect(await screen.findByText('0.00 req/s')).toBeInTheDocument()
    expect(screen.getByText('20 requests in selected range')).toBeInTheDocument()
    expect(screen.getByText('1.0 MiB')).toBeInTheDocument()
    expect(screen.getByRole('img', { name: 'HTTP requests time series' })).toBeInTheDocument()
    expect(screen.getAllByText('Not reported by this service in this range.')).toHaveLength(6)

    const urls = fetchMock.mock.calls.map(([input]) => new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test'))
    expect(urls).toHaveLength(3)
    for (const url of urls) {
      expect(url.searchParams.get('from')).toBe('2026-08-13T14:45:00.000Z')
      expect(url.searchParams.get('to')).toBe('2026-08-13T15:00:00.000Z')
    }
    const detail = urls.find((url) => url.pathname.endsWith('/overview'))!
    expect(detail.searchParams.get('serviceName')).toBe('checkout')
    expect(detail.searchParams.get('serviceNamespace')).toBe('store')
    expect(detail.searchParams.get('environment')).toBe('local')
    const seriesUrl = urls.find((url) => url.pathname.endsWith('/series'))!
    expect(seriesUrl.searchParams.getAll('metric')).toHaveLength(7)
  })

  it('uses one new aligned absolute interval when the range changes', async () => {
    const fetchMock = mockMetricsApi()
    renderMetrics()
    await screen.findByRole('heading', { name: 'Metrics' })

    vi.setSystemTime(new Date('2026-08-13T16:00:00.000Z'))
    await userEvent.click(screen.getByRole('button', { name: '1h' }))

    await waitFor(() => {
      const urls = fetchMock.mock.calls.map(([input]) => new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test'))
      const updated = urls.filter((url) => url.searchParams.get('to') === '2026-08-13T16:00:00.000Z')
      expect(updated).toHaveLength(3)
      updated.forEach((url) => expect(url.searchParams.get('from')).toBe('2026-08-13T15:00:00.000Z'))
    })
  })

  it('queries the selected composite service identity', async () => {
    const second = { name: 'checkout', namespace: null, environment: 'staging' }
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
      if (url.pathname.endsWith('/services')) return response({ services: [service, second] })
      if (url.pathname.endsWith('/overview')) return response({ ...overview, service: second })
      return response({ ...series, service: second })
    })
    renderMetrics()
    const selector = await screen.findByRole('combobox', { name: 'Service' })

    await userEvent.selectOptions(selector, '[null,"checkout","staging"]')

    await waitFor(() => {
      const matchingCalls = fetchMock.mock.calls.filter(([input]) => {
        const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
        return url.searchParams.get('environment') === 'staging'
      })
      expect(matchingCalls).toHaveLength(2)
      matchingCalls.forEach(([input]) => {
        const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
        expect(url.searchParams.get('serviceNamespace')).toBeNull()
      })
    })
  })

  it('never presents the previous service values while a new identity is loading', async () => {
    const second = { name: 'checkout', namespace: null, environment: 'staging' }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
      if (url.pathname.endsWith('/services')) return response({ services: [service, second] })
      if (url.searchParams.get('environment') === 'staging') return new Promise<Response>(() => undefined)
      if (url.pathname.endsWith('/overview')) return response(overview)
      return response(series)
    })
    renderMetrics()
    const selector = await screen.findByRole('combobox', { name: 'Service' })
    expect(await screen.findByText('20 requests in selected range')).toBeInTheDocument()

    await userEvent.selectOptions(selector, '[null,"checkout","staging"]')

    expect(await screen.findByText('Loading operational metrics…')).toBeInTheDocument()
    expect(screen.queryByText('20 requests in selected range')).not.toBeInTheDocument()
    expect(screen.queryByRole('img', { name: 'HTTP requests time series' })).not.toBeInTheDocument()
  })

  it('explains when no monitored service has metrics in the selected range', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => response({ services: [] }))
    renderMetrics()

    expect(await screen.findByRole('heading', { name: 'No monitored services found' })).toBeInTheDocument()
    expect(screen.getByText(/Send OpenTelemetry metrics/)).toBeInTheDocument()
  })

  it('distinguishes an unavailable metrics backend and retries service discovery', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockImplementationOnce(() => response({}, 503))
      .mockImplementation(() => response({ services: [] }))
    renderMetrics()

    expect(await screen.findByRole('alert')).toHaveTextContent('Metrics storage is unavailable.')
    await userEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(await screen.findByRole('heading', { name: 'No monitored services found' })).toBeInTheDocument()
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('shows a whole-range empty state without treating absence as zero', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
      if (url.pathname.endsWith('/services')) return response({ services: [service] })
      if (url.pathname.endsWith('/overview')) return response({ ...overview, values: [] })
      return response({ ...series, series: [] })
    })
    renderMetrics()

    expect(await screen.findByText(/No metrics received for checkout in the last 15m/)).toBeInTheDocument()
    expect(screen.queryByText('0.00 req/s')).not.toBeInTheDocument()
  })

  it('keeps summary and chart failures independent', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
      if (url.pathname.endsWith('/services')) return response({ services: [service] })
      if (url.pathname.endsWith('/overview')) return response({}, 500)
      return response(series)
    })
    renderMetrics()

    expect(await screen.findByText(/Summary values could not be loaded/)).toBeInTheDocument()
    expect(screen.getByRole('img', { name: 'HTTP requests time series' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Retry summary' })).toBeInTheDocument()
  })
})
