import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { BurnRateEvaluation, SloDefinitionsResponse, SloEvaluation, SloUnavailableReason } from '../../api/slos'
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

function rawResponse(body: string, status = 200) {
  return Promise.resolve(new Response(body, { status, headers: { 'Content-Type': 'application/json' } }))
}

function urlOf(input: RequestInfo | URL) {
  return new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
}

function evaluation(
  id: string,
  status: 'MET' | 'BREACHED' | 'UNAVAILABLE',
  observedValue: number | null,
  reason: SloUnavailableReason | null = null,
  burnOverride: Partial<BurnRateEvaluation> = {},
): SloEvaluation {
  const definition = definitions.slos.find((item) => item.id === id)!
  const allowedBadRatio = definition.sliType === 'AVAILABILITY' ? 1 - definition.target : definition.target
  const observedBadRatio = observedValue === null ? null : definition.sliType === 'AVAILABILITY' ? 1 - observedValue : observedValue
  const burnAvailable = observedBadRatio !== null && allowedBadRatio > 0
  return {
    sloId: id,
    service: definition.service,
    sliType: definition.sliType,
    target: definition.target,
    window: definition.window,
    range,
    evaluatedAt: range.to,
    observedValue,
    requestCount: observedValue === null ? null : 20,
    status,
    reason,
    burnRateEvaluation: {
      allowedBadRatio,
      observedBadRatio,
      burnRate: burnAvailable ? observedBadRatio / allowedBadRatio : null,
      status: burnAvailable ? 'AVAILABLE' : 'UNAVAILABLE',
      reason: burnAvailable ? null : reason,
      ...burnOverride,
    },
  }
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

  it('renders SLI-aware targets, burn evidence, exact range, unavailable state, and an exact Investigation link', async () => {
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
    expect(screen.getAllByText('Target ≥')).not.toHaveLength(0)
    expect(screen.getByText('Target ≤')).toBeInTheDocument()
    expect(screen.getByLabelText('SLO status: Breached')).toHaveTextContent('BREACHED')
    expect(screen.getByLabelText('SLO status: Unavailable')).toHaveTextContent('UNAVAILABLE')
    expect(screen.getByText('No traffic in this evaluation window.')).toBeInTheDocument()
    expect(screen.getByLabelText('Burn-rate data status: Available')).toHaveTextContent('AVAILABLE')
    expect(screen.getByLabelText('Burn-rate data status: Unavailable')).toHaveTextContent('UNAVAILABLE')
    expect(screen.getByText('0.1%')).toBeInTheDocument()
    expect(screen.getByText('2%')).toBeInTheDocument()
    expect(screen.getByText('20×')).toBeInTheDocument()
    expect(screen.getByText('Burn rate is unavailable because there was no traffic in this evaluation window.')).toBeInTheDocument()
    expect(screen.getAllByText('Exact half-open interval [from, to)')).toHaveLength(2)
    expect(screen.getAllByText(range.from)).toHaveLength(2)
    expect(screen.getAllByText(range.to)).toHaveLength(2)
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
    expect(screen.getByText('0%')).toBeInTheDocument()
    expect(screen.getByText('0×')).toBeInTheDocument()
  })

  it('renders burn rates exactly at and above the sustainable rate', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname === '/api/slos') return response({ slos: [definitions.slos[0], definitions.slos[1]] })
      if (url.pathname.endsWith('/checkout-availability/evaluation')) {
        return response(evaluation('checkout-availability', 'MET', 0.999, null, { observedBadRatio: 0.001, burnRate: 1 }))
      }
      return response(evaluation('checkout-errors', 'BREACHED', 0.04, null, { observedBadRatio: 0.04, burnRate: 4 }))
    })
    renderPage()

    expect(await screen.findByText('1×')).toBeInTheDocument()
    expect(screen.getByText('4×')).toBeInTheDocument()
    expect(screen.getByText('Observed availability')).toBeInTheDocument()
    expect(screen.getByText('Observed error rate')).toBeInTheDocument()
  })

  it('explains a zero allowed bad ratio without displaying a non-finite burn rate', async () => {
    const perfect = { ...definitions.slos[0], target: 1 }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname === '/api/slos'
      ? response({ slos: [perfect] })
      : response({
          ...evaluation('checkout-availability', 'MET', 1),
          target: 1,
          burnRateEvaluation: {
            allowedBadRatio: 0,
            observedBadRatio: 0,
            burnRate: null,
            status: 'UNAVAILABLE',
            reason: 'ZERO_ALLOWED_BAD_RATIO',
          },
        }))
    renderPage()

    expect(await screen.findByText('Burn rate is unavailable because this objective allows no bad events.')).toBeInTheDocument()
    expect(screen.queryByText(/Infinity|NaN/)).not.toBeInTheDocument()
  })

  it('keeps near-perfect targets and positive allowed ratios distinct from their boundaries', async () => {
    const nearPerfect = { ...definitions.slos[0], target: 0.9999999 }
    const result = {
      ...evaluation('checkout-availability', 'MET', 0.9999999),
      target: nearPerfect.target,
      burnRateEvaluation: {
        allowedBadRatio: 0.0000001,
        observedBadRatio: 0.0000001,
        burnRate: 1,
        status: 'AVAILABLE',
        reason: null,
      },
    }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname === '/api/slos'
      ? response({ slos: [nearPerfect] })
      : response(result))
    renderPage()

    expect(await screen.findByText('99.99999%')).toBeInTheDocument()
    expect(screen.getAllByText('0.00001%')).toHaveLength(2)
    expect(screen.queryByText('100%')).not.toBeInTheDocument()
    expect(screen.queryByText('0%')).not.toBeInTheDocument()
  })

  it('does not render non-finite numbers from an out-of-contract JSON payload', async () => {
    const base = JSON.stringify(evaluation('checkout-availability', 'BREACHED', 0.98, null, {
      allowedBadRatio: 0.001,
      observedBadRatio: 0.02,
      burnRate: 20,
    }))
    const invalidPayload = base
      .replace(/"observedValue":[^,]+/, '"observedValue":1e400')
      .replace(/"requestCount":[^,]+/, '"requestCount":1e400')
      .replace(/"allowedBadRatio":[^,]+/, '"allowedBadRatio":1e400')
      .replace(/"observedBadRatio":[^,]+/, '"observedBadRatio":1e400')
      .replace(/"burnRate":[^,]+/, '"burnRate":1e400')
    const invalidDefinitions = JSON.stringify({ slos: [definitions.slos[0]] })
      .replace(/"target":[^,]+/, '"target":1e400')
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname === '/api/slos'
      ? rawResponse(invalidDefinitions)
      : rawResponse(invalidPayload))
    renderPage()

    expect(await screen.findByLabelText('SLO status: Breached')).toBeInTheDocument()
    expect(screen.getAllByText('Unavailable').length).toBeGreaterThanOrEqual(5)
    expect(document.body).not.toHaveTextContent(/Infinity|NaN|∞/)
  })

  it('hides previous evidence and Investigation context while an evaluation is refetching', async () => {
    const user = userEvent.setup()
    let evaluationCalls = 0
    let resolveRefresh: ((value: Response) => void) | undefined
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname === '/api/slos') return response({ slos: [definitions.slos[0]] })
      evaluationCalls += 1
      if (evaluationCalls === 1) return response(evaluation('checkout-availability', 'BREACHED', 0.996, null, { observedBadRatio: 0.004, burnRate: 4 }))
      return new Promise<Response>((resolve) => { resolveRefresh = resolve })
    })
    renderPage()

    expect(await screen.findByText('4×')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Refresh objectives' }))
    expect(await screen.findByText('Refreshing objective and burn-rate evidence…')).toBeInTheDocument()
    expect(screen.queryByText('4×')).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Investigate service' })).not.toBeInTheDocument()

    resolveRefresh?.(await response(evaluation('checkout-availability', 'MET', 0.999, null, { observedBadRatio: 0.001, burnRate: 1 })))
    await waitFor(() => expect(screen.getByText('1×')).toBeInTheDocument())
  })

  it('uses every evaluation-relevant definition field in the query key to prevent old status reuse', () => {
    const initial = definitions.slos[0]
    const targetChanged = { ...initial, target: 0.99 }
    const identityChanged = { ...initial, service: { ...initial.service, environment: 'staging' } }

    expect(sloEvaluationQueryKey(targetChanged)).not.toEqual(sloEvaluationQueryKey(initial))
    expect(sloEvaluationQueryKey(identityChanged)).not.toEqual(sloEvaluationQueryKey(initial))
  })
})
