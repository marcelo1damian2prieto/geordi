import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ServiceMapResponse } from '../../api/serviceMap'
import { ServiceMapPage } from './ServiceMapPage'

vi.mock('./ServiceMapGraph', () => ({
  ServiceMapGraph: ({ nodeCount, edgeCount }: { nodeCount: number; edgeCount: number }) => (
    <div role="img" aria-label={`Observed dependency graph with ${nodeCount} services and ${edgeCount} dependencies`} />
  ),
}))

const range = { from: '2026-08-20T10:00:00.000Z', to: '2026-08-20T11:00:00.000Z' }
const storefront = { name: 'checkout', namespace: 'storefront', environment: 'development' }
const fulfillment = { name: 'checkout', namespace: 'fulfillment', environment: 'development' }
const inventory = { name: 'inventory', namespace: null, environment: 'development' }
const fixture = {
  context: { environment: 'development', range },
  nodes: [storefront, fulfillment, inventory],
  edges: [
    {
      caller: storefront,
      callee: fulfillment,
      evidenceCount: 2,
      evidence: [
        { traceId: 'a'.repeat(32), observedAt: '2026-08-20T10:12:00.000Z' },
        { traceId: 'b'.repeat(32), observedAt: '2026-08-20T10:18:00.000Z' },
      ],
    },
    {
      caller: fulfillment,
      callee: inventory,
      evidenceCount: 1,
      evidence: [{ traceId: 'c'.repeat(32), observedAt: '2026-08-20T10:22:00.000Z' }],
    },
  ],
  truncated: false,
} satisfies ServiceMapResponse

const entry = `/service-map?environment=development&from=${encodeURIComponent(range.from)}&to=${encodeURIComponent(range.to)}`

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
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route path="/service-map" element={<ServiceMapPage />} />
          <Route path="/investigate" element={<div>Investigation destination</div>} />
          <Route path="/traces/:traceId" element={<div>Trace destination</div>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks() })

describe('Service Map', () => {
  it('renders the contract fixture with exact namespace identities, direction, and bounded evidence', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(() => response(fixture))
    renderPage()

    expect(screen.getByText('Loading observed dependencies…')).toBeInTheDocument()
    expect(await screen.findByRole('heading', { name: 'Service map' })).toBeInTheDocument()
    expect(await screen.findByRole('img', { name: 'Observed dependency graph with 3 services and 2 dependencies' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Investigate storefront / checkout' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Investigate fulfillment / checkout' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Investigate inventory (no namespace)' })).toBeInTheDocument()
    expect(screen.getByText('storefront / checkout → fulfillment / checkout')).toBeInTheDocument()
    expect(screen.getByText('2 distinct traces observed')).toBeInTheDocument()

    const request = urlOf(fetchMock.mock.calls[0][0])
    expect(request.searchParams.get('environment')).toBe('development')
    expect(request.searchParams.get('from')).toBe(range.from)
    expect(request.searchParams.get('to')).toBe(range.to)
  })

  it('preserves exact node context and sends evidence to Trace Detail with a safe Service Map origin', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => response(fixture))
    renderPage()

    const node = await screen.findByRole('link', { name: 'Investigate storefront / checkout' })
    const nodeTarget = new URL(node.getAttribute('href')!, 'http://geordi.test')
    expect(nodeTarget.pathname).toBe('/investigate')
    expect(nodeTarget.searchParams.get('serviceName')).toBe('checkout')
    expect(nodeTarget.searchParams.get('serviceNamespace')).toBe('storefront')
    expect(nodeTarget.searchParams.get('environment')).toBe('development')
    expect(nodeTarget.searchParams.get('from')).toBe(range.from)
    expect(nodeTarget.searchParams.get('to')).toBe(range.to)

    const evidence = screen.getByRole('link', { name: `Open trace ${'a'.repeat(32)}` })
    const evidenceTarget = new URL(evidence.getAttribute('href')!, 'http://geordi.test')
    expect(evidenceTarget.pathname).toBe(`/traces/${'a'.repeat(32)}`)
    expect(evidenceTarget.searchParams.get('origin')).toBe('service-map')
    expect(evidenceTarget.searchParams.get('serviceNamespace')).toBe('fulfillment')
    expect(evidenceTarget.searchParams.get('environment')).toBe('development')
    expect(evidenceTarget.searchParams.get('from')).toBe(range.from)
    expect(evidenceTarget.searchParams.get('to')).toBe(range.to)
  })

  it('distinguishes empty and explicitly truncated successful results', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockImplementationOnce(() => response({ ...fixture, nodes: [], edges: [] }))
      .mockImplementationOnce(() => response({ ...fixture, truncated: true }))
    const first = renderPage()
    expect(await screen.findByRole('heading', { name: 'No observed dependencies' })).toBeInTheDocument()
    expect(screen.getByText(/does not prove that no dependency exists/i)).toBeInTheDocument()
    first.unmount()

    renderPage()
    expect(await screen.findByRole('status')).toHaveTextContent(/bounded and incomplete/i)
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it.each([
    [400, 'Invalid service map context'],
    [404, 'Service Map is not enabled for this Geordi deployment.'],
    [502, 'Trace storage returned an invalid response.'],
    [503, 'Trace storage is unavailable.'],
    [504, 'Trace storage timed out.'],
  ])('distinguishes failure status %i', async (status, heading) => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => response({}, status))
    renderPage()
    expect(await screen.findByRole('heading', { name: heading })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Retry' })).toBeInTheDocument()
  })

  it.each([
    '/service-map?environment=development&from=not-a-time',
    '/service-map?environment=development&from=2026-02-30T10%3A00%3A00Z&to=2026-02-30T11%3A00%3A00Z',
    '/service-map?environment=development&from=2026-08-20%2010%3A00%3A00Z&to=2026-08-20T11%3A00%3A00Z',
    '/service-map?environment=development&from=2026-08-20&to=2026-08-21',
  ])('rejects malformed bookmark %s without issuing a request', (malformedEntry) => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
    renderPage(malformedEntry)
    expect(screen.getByRole('heading', { name: 'Invalid service map context' })).toBeInTheDocument()
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('suppresses the previous graph when a refresh fails', async () => {
    vi.spyOn(globalThis, 'fetch')
      .mockImplementationOnce(() => response(fixture))
      .mockImplementationOnce(() => response({}, 503))
    renderPage()
    expect(await screen.findByText('storefront / checkout → fulfillment / checkout')).toBeInTheDocument()

    await userEvent.click(screen.getByRole('button', { name: 'Refresh' }))

    expect(await screen.findByRole('heading', { name: 'Trace storage is unavailable.' })).toBeInTheDocument()
    expect(screen.queryByText('storefront / checkout → fulfillment / checkout')).not.toBeInTheDocument()
  })

  it('never presents the previous environment while the next query is pending', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.searchParams.get('environment') === 'staging') return new Promise<Response>(() => undefined)
      return response(fixture)
    })
    renderPage()
    expect(await screen.findByText('storefront / checkout → fulfillment / checkout')).toBeInTheDocument()

    const input = screen.getByRole('textbox', { name: 'Environment' })
    await userEvent.clear(input)
    await userEvent.type(input, 'staging')
    await userEvent.click(screen.getByRole('button', { name: 'Apply environment' }))

    expect(await screen.findByText('Loading observed dependencies…')).toBeInTheDocument()
    expect(screen.queryByText('storefront / checkout → fulfillment / checkout')).not.toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole('textbox', { name: 'Environment' })).toHaveValue('staging'))
  })
})
