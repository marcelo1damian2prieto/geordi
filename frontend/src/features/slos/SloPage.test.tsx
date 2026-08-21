import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { SloDefinitionsResponse } from '../../api/slos'
import { SloPage } from './SloPage'
import { sloEvaluationQueryKey } from './useSlos'

const range = { from: '2026-08-20T10:00:00.000Z', to: '2026-08-20T10:15:00.000Z' }
const service = { name: 'checkout', namespace: 'storefront', environment: 'production' }
const definitions = {
  slos: [
    { id: 'checkout-availability', name: 'Checkout availability', description: null, service, sliType: 'AVAILABILITY', target: 0.999, window: 'PT15M', enabled: true },
    { id: 'checkout-errors', name: 'Checkout errors', description: 'Error objective', service: { ...service, namespace: null }, sliType: 'ERROR_RATE', target: 0.01, window: 'PT15M', enabled: true },
    { id: 'disabled', name: 'Disabled objective', description: null, service, sliType: 'AVAILABILITY', target: 0.99, window: 'PT5M', enabled: false },
  ],
} satisfies SloDefinitionsResponse

function response(body: unknown, status = 200) {
  return Promise.resolve(new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } }))
}

function urlOf(input: RequestInfo | URL) {
  return new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
}

function evaluation(id: string, status: 'MET' | 'BREACHED' | 'UNAVAILABLE', observedValue: number | null, reason: string | null = null) {
  const definition = definitions.slos.find((item) => item.id === id)!
  return { sloId: id, service: definition.service, sliType: definition.sliType, target: definition.target, window: definition.window, range, evaluatedAt: range.to, observedValue, requestCount: observedValue === null ? null : 20, status, reason }
}

function renderPage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(<QueryClientProvider client={client}><MemoryRouter><SloPage /></MemoryRouter></QueryClientProvider>)
}

afterEach(() => vi.restoreAllMocks())

describe('SLOs', () => {
  it('shows a loading state before the deployment-managed catalog is available', () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => new Promise<Response>(() => undefined))
    renderPage()

    expect(screen.getByText('Loading service-level objectives…')).toBeInTheDocument()
    expect(screen.getByText('Loading service-level objectives…')).toHaveAttribute('aria-busy', 'true')
  })

  it('renders exact definitions, textual evaluation states, and an exact Investigation link', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname === '/api/slos') return response(definitions)
      if (url.pathname.endsWith('/checkout-availability/evaluation')) return response(evaluation('checkout-availability', 'BREACHED', 0.98))
      if (url.pathname.endsWith('/checkout-errors/evaluation')) return response(evaluation('checkout-errors', 'UNAVAILABLE', null, 'NO_TRAFFIC'))
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage()

    expect(await screen.findByRole('heading', { name: 'Service-level objectives' })).toBeInTheDocument()
    expect(screen.getByText('Checkout availability')).toBeInTheDocument()
    expect(screen.getAllByText('storefront / checkout · production')).not.toHaveLength(0)
    expect(screen.getAllByText('Availability')).not.toHaveLength(0)
    expect(screen.getByText('99.9%')).toBeInTheDocument()
    expect(screen.getByLabelText('SLO status: Breached')).toHaveTextContent('BREACHED')
    expect(screen.getByLabelText('SLO status: Unavailable')).toHaveTextContent('UNAVAILABLE')
    expect(screen.getByText('No traffic in this evaluation window.')).toBeInTheDocument()
    expect(screen.getByText('Disabled — not evaluated')).toBeInTheDocument()

    const investigate = screen.getAllByRole('link', { name: 'Investigate service' })[0]
    const target = new URL(investigate.getAttribute('href')!, 'http://geordi.test')
    expect(target.pathname).toBe('/investigate')
    expect(target.searchParams.get('serviceName')).toBe('checkout')
    expect(target.searchParams.get('serviceNamespace')).toBe('storefront')
    expect(target.searchParams.get('environment')).toBe('production')
    expect(target.searchParams.get('from')).toBe(range.from)
    expect(target.searchParams.get('to')).toBe(range.to)
  })

  it('distinguishes an empty catalog and an evaluation-provider failure', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementationOnce(() => response({ slos: [] }))
    renderPage()
    expect(await screen.findByRole('heading', { name: 'No service-level objectives configured' })).toBeInTheDocument()
    expect(fetchMock).toHaveBeenCalledTimes(1)

    vi.restoreAllMocks()
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname === '/api/slos'
      ? response({ slos: [definitions.slos[0]] }) : response({}, 503))
    renderPage()
    expect(await screen.findByRole('alert')).toHaveTextContent('SLO evaluation is unavailable.')
  })

  it('renders a met evaluation as an explicit accessible status', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname === '/api/slos') return response({ slos: [definitions.slos[0]] })
      return response(evaluation('checkout-availability', 'MET', 1))
    })
    renderPage()

    expect(await screen.findByLabelText('SLO status: Met')).toHaveTextContent('MET')
    expect(screen.getByText('100%')).toBeInTheDocument()
  })

  it('uses every evaluation-relevant definition field in the query key to prevent old status reuse', () => {
    const initial = definitions.slos[0]
    const targetChanged = { ...initial, target: 0.99 }
    const identityChanged = { ...initial, service: { ...initial.service, environment: 'staging' } }

    expect(sloEvaluationQueryKey(targetChanged)).not.toEqual(sloEvaluationQueryKey(initial))
    expect(sloEvaluationQueryKey(identityChanged)).not.toEqual(sloEvaluationQueryKey(initial))
  })
})
