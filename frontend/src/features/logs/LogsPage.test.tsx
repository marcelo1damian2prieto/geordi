import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { LogSearchResponse } from '../../api/logs'
import type { ServiceIdentity } from '../../api/telemetryContext'
import { LogsPage } from './LogsPage'

const service = { name: 'checkout', namespace: 'store', environment: 'local' } satisfies ServiceIdentity
const staging = { name: 'checkout', namespace: null, environment: 'staging' } satisfies ServiceIdentity
const range = { from: '2026-08-13T14:45:00.000Z', to: '2026-08-13T15:00:00.000Z' }
const entry = `/logs?serviceName=checkout&serviceNamespace=store&environment=local&from=${encodeURIComponent(range.from)}&to=${encodeURIComponent(range.to)}`
const result = {
  service, range,
  logs: [
    {
      timestamp: '2026-08-13T14:59:08.218Z', observedTimestamp: '2026-08-13T14:59:08.220Z', severity: 'ERROR',
      severityText: 'ERROR', body: 'Payment provider rejected request', service,
      traceId: 'a'.repeat(32), spanId: 'b'.repeat(16), attributes: { 'error.type': 'PaymentRejected', request_id: 'request-1' },
    },
    {
      timestamp: '2026-08-13T14:58:00.000Z', observedTimestamp: null, severity: 'INFO', severityText: null,
      body: 'Checkout completed', service, traceId: null, spanId: null, attributes: {},
    },
  ],
} satisfies LogSearchResponse

function response(body: unknown, status = 200) {
  return Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }))
}

function urlOf(input: RequestInfo | URL) {
  return new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
}

function renderPage(initialEntry = entry) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(<QueryClientProvider client={client}><MemoryRouter initialEntries={[initialEntry]}><LogsPage /></MemoryRouter></QueryClientProvider>)
}

beforeEach(() => vi.setSystemTime(new Date(range.to)))
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks() })

describe('Logs', () => {
  it('renders newest-first contract records, detail, and sends exact bounded filters', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname === '/api/logs/services') return response({ services: [service] })
      if (url.pathname === '/api/logs') return response(result)
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage(`${entry}&severity=ERROR&text=rejected&traceId=${'a'.repeat(32)}&spanId=${'b'.repeat(16)}`)

    expect(screen.getByText('Searching logs…')).toBeInTheDocument()
    expect(await screen.findByText('Payment provider rejected request')).toBeInTheDocument()
    expect(screen.getAllByText('ERROR').length).toBeGreaterThan(0)
    expect(screen.getByText('Trace linked')).toBeInTheDocument()
    expect(screen.getByText('Payment provider rejected request').compareDocumentPosition(screen.getByText('Checkout completed')) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    await userEvent.click(screen.getAllByText('Log details')[0])
    expect(screen.getByText('PaymentRejected')).toBeInTheDocument()

    const request = fetchMock.mock.calls.map(([input]) => urlOf(input)).find((url) => url.pathname === '/api/logs')!
    expect(request.searchParams.get('serviceNamespace')).toBe('store')
    expect(request.searchParams.get('environment')).toBe('local')
    expect(request.searchParams.get('severity')).toBe('ERROR')
    expect(request.searchParams.get('text')).toBe('rejected')
    expect(request.searchParams.get('traceId')).toBe('a'.repeat(32))
    expect(request.searchParams.get('spanId')).toBe('b'.repeat(16))
    expect(request.searchParams.get('limit')).toBe('100')
  })

  it('distinguishes empty results and provider failure', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname === '/api/logs/services') return response({ services: [service] })
      return response({ ...result, logs: [] })
    })
    renderPage(`${entry}&severity=ERROR`)
    expect(await screen.findByText(/No logs found for checkout.*severity ERROR/)).toBeInTheDocument()

    vi.restoreAllMocks()
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname.endsWith('/services')
      ? response({ services: [service] }) : response({}, 503))
    renderPage()
    expect(await screen.findByRole('alert')).toHaveTextContent('Log storage is unavailable.')
  })

  it('removes prior-service records while the new exact identity loads', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname.endsWith('/services')) return response({ services: [service, staging] })
      if (url.searchParams.get('environment') === 'staging') return new Promise<Response>(() => undefined)
      return response(result)
    })
    renderPage()
    expect(await screen.findByText('Payment provider rejected request')).toBeInTheDocument()

    await userEvent.selectOptions(screen.getByRole('combobox', { name: 'Service and environment' }), '[null,"checkout","staging"]')

    expect(await screen.findByText('Searching logs…')).toBeInTheDocument()
    expect(screen.queryByText('Payment provider rejected request')).not.toBeInTheDocument()
  })

  it('rejects malformed correlation bookmarks without requests', () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
    renderPage(`${entry}&traceId=not-a-trace`)

    expect(screen.getByRole('heading', { name: 'Invalid Logs context' })).toBeInTheDocument()
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('submits literal text explicitly rather than on each keystroke', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname.endsWith('/services')
      ? response({ services: [service] }) : response(result))
    renderPage()
    await screen.findByText('Payment provider rejected request')
    const initialSearches = fetchMock.mock.calls.filter(([input]) => urlOf(input).pathname === '/api/logs').length
    await userEvent.type(screen.getByRole('textbox', { name: 'Message contains' }), 'rejected')
    expect(fetchMock.mock.calls.filter(([input]) => urlOf(input).pathname === '/api/logs')).toHaveLength(initialSearches)
    await userEvent.click(screen.getByRole('button', { name: 'Search' }))
    await waitFor(() => expect(fetchMock.mock.calls.some(([input]) => urlOf(input).searchParams.get('text') === 'rejected')).toBe(true))
  })
})
