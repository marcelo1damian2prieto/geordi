import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ServiceIdentity } from '../../api/telemetryContext'
import type { TraceSearchResponse } from '../../api/traces'
import { TraceSearchPage } from './TraceSearchPage'

const service = { name: 'checkout', namespace: 'store', environment: 'local' } satisfies ServiceIdentity
const range = { from: '2026-08-13T14:45:00.000Z', to: '2026-08-13T15:00:00.000Z' }
const searchResult = {
  service,
  range,
  traces: [
    { traceId: 'a'.repeat(32), rootSpanName: 'GET /checkout', startTime: '2026-08-13T14:59:00Z', durationNanos: 125_000_000, spanCount: 3, error: false },
    { traceId: 'b'.repeat(32), rootSpanName: 'POST /checkout', startTime: '2026-08-13T14:58:00Z', durationNanos: 800_000_000, spanCount: 4, error: true },
  ],
} satisfies TraceSearchResponse

function response(body: unknown, status = 200) {
  return Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }))
}

function requestUrl(input: RequestInfo | URL) {
  return new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
}

function renderSearch(entry = '/traces?serviceName=checkout&serviceNamespace=store&environment=local&from=2026-08-13T14%3A45%3A00.000Z&to=2026-08-13T15%3A00%3A00.000Z') {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(<QueryClientProvider client={client}><MemoryRouter initialEntries={[entry]}><TraceSearchPage /></MemoryRouter></QueryClientProvider>)
}

beforeEach(() => vi.setSystemTime(new Date('2026-08-13T15:00:00.000Z')))
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks() })

describe('Trace search', () => {
  it('retains Metrics context even when discovery does not contain the service and renders contract-shaped results', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = requestUrl(input)
      if (url.pathname === '/api/traces/services') return response({ services: [] })
      if (url.pathname === '/api/traces') return response(searchResult)
      throw new Error(`Unexpected trace request: ${url.pathname}`)
    })

    renderSearch()

    expect(screen.getByText('Searching traces…')).toBeInTheDocument()
    expect(await screen.findByRole('heading', { name: 'Trace results' })).toBeInTheDocument()
    expect(screen.getByRole('combobox', { name: 'Service' })).toHaveDisplayValue('store / checkout · local')
    expect(screen.getByRole('link', { name: 'GET /checkout' })).toHaveAttribute('href', expect.stringContaining('/traces/aaaaaaaa'))
    expect(screen.getByText('125.0 ms')).toBeInTheDocument()
    expect(screen.getByText('ERROR')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Investigate service' })).toHaveAttribute(
      'href',
      '/investigate?serviceName=checkout&serviceNamespace=store&environment=local&from=2026-08-13T14%3A45%3A00.000Z&to=2026-08-13T15%3A00%3A00.000Z',
    )

    const urls = fetchMock.mock.calls.map(([input]) => requestUrl(input))
    const search = urls.find((url) => url.pathname === '/api/traces')!
    expect(search.searchParams.get('serviceName')).toBe('checkout')
    expect(search.searchParams.get('serviceNamespace')).toBe('store')
    expect(search.searchParams.get('environment')).toBe('local')
    expect(search.searchParams.get('from')).toBe(range.from)
    expect(search.searchParams.get('to')).toBe(range.to)
  })

  it('represents a carried one-hour range accurately', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = requestUrl(input)
      return url.pathname === '/api/traces/services' ? response({ services: [service] }) : response(searchResult)
    })
    renderSearch('/traces?serviceName=checkout&serviceNamespace=store&environment=local&from=2026-08-13T14%3A00%3A00.000Z&to=2026-08-13T15%3A00%3A00.000Z')

    expect(await screen.findByRole('button', { name: '1h' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: '15m' })).toHaveAttribute('aria-pressed', 'false')
  })

  it('refreshes a custom absolute context without replacing its range', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = requestUrl(input)
      return url.pathname === '/api/traces/services' ? response({ services: [service] }) : response(searchResult)
    })
    const customFrom = '2026-08-13T13:45:00.000Z'
    renderSearch(`/traces?serviceName=checkout&serviceNamespace=store&environment=local&from=${encodeURIComponent(customFrom)}&to=2026-08-13T15%3A00%3A00.000Z`)
    await screen.findByRole('heading', { name: 'Trace results' })

    await userEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    await waitFor(() => expect(fetchMock.mock.calls.length).toBeGreaterThanOrEqual(4))
    const traceRequests = fetchMock.mock.calls.map(([input]) => requestUrl(input)).filter((url) => url.pathname === '/api/traces')
    expect(traceRequests.every((url) => url.searchParams.get('from') === customFrom)).toBe(true)
  })

  it('shows a selected-service empty result and sends the optional error filter', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = requestUrl(input)
      if (url.pathname === '/api/traces/services') return response({ services: [service] })
      if (url.pathname === '/api/traces') return response({ ...searchResult, traces: [] })
      throw new Error(`Unexpected trace request: ${url.pathname}`)
    })
    renderSearch()

    await screen.findByText(/No traces found for checkout/)
    await userEvent.click(screen.getByRole('checkbox', { name: 'Errors only' }))

    await waitFor(() => {
      const searches = fetchMock.mock.calls.map(([input]) => requestUrl(input)).filter((url) => url.pathname === '/api/traces')
      expect(searches.some((url) => url.searchParams.get('errorOnly') === 'true')).toBe(true)
    })
    expect(await screen.findByText(/with errors/)).toBeInTheDocument()
  })

  it('distinguishes unavailable storage and retries discovery', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockImplementationOnce(() => response({}, 503))
      .mockImplementationOnce(() => response(searchResult))
      .mockImplementation(() => response({ services: [] }))
    renderSearch('/traces')

    expect(await screen.findByRole('alert')).toHaveTextContent('Trace storage is unavailable.')
    await userEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(await screen.findByRole('heading', { name: 'No services with traces found' })).toBeInTheDocument()
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('shows when no service has traces in the selected interval', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => response({ services: [] }))
    renderSearch('/traces')

    expect(await screen.findByRole('heading', { name: 'No services with traces found' })).toBeInTheDocument()
  })
})
