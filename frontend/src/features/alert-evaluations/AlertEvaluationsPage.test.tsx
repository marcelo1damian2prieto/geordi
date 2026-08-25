import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type {
  AlertEvaluation,
  AlertPoliciesResponse,
  AlertPolicy,
  AlertUnavailableReason,
} from '../../api/alertEvaluations'
import { AlertEvaluationsPage } from './AlertEvaluationsPage'
import { alertEvaluationQueryKey } from './useAlertEvaluations'

const range = { from: '2026-08-25T10:00:00.000Z', to: '2026-08-25T10:15:00.000Z' }
const service = { name: 'checkout', namespace: 'storefront', environment: 'production' }
const enabledPolicy: AlertPolicy = {
  id: 'checkout-burn',
  name: 'Checkout burn',
  description: 'Current checkout availability burn.',
  enabled: true,
  sloId: 'checkout-availability',
  condition: { type: 'BURN_RATE_ABOVE', threshold: 2 },
}
const disabledPolicy: AlertPolicy = {
  id: 'disabled-burn',
  name: 'Disabled burn policy',
  description: null,
  enabled: false,
  sloId: 'checkout-availability',
  condition: { type: 'BURN_RATE_ABOVE', threshold: 4 },
}
const policies: AlertPoliciesResponse = { alertPolicies: [enabledPolicy, disabledPolicy] }

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
  status: AlertEvaluation['status'],
  observedBurnRate: number | null,
  reason: AlertUnavailableReason | null = null,
  overrides: Partial<AlertEvaluation> = {},
): AlertEvaluation {
  return {
    policyId: enabledPolicy.id,
    policyName: enabledPolicy.name,
    sloId: enabledPolicy.sloId,
    condition: enabledPolicy.condition,
    status,
    reason,
    evidence: { service, window: 'PT15M', range, evaluatedAt: range.to, observedBurnRate },
    ...overrides,
  }
}

function renderPage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter><AlertEvaluationsPage /></MemoryRouter>
    </QueryClientProvider>,
  )
}

afterEach(() => vi.restoreAllMocks())

describe('Alert evaluations', () => {
  it('shows a loading state before the policy catalog is available', () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => new Promise<Response>(() => undefined))
    renderPage()

    expect(screen.getByText('Loading alert policies…')).toHaveAttribute('aria-busy', 'true')
  })

  it('renders an explainable condition result and exact Investigation context', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname === '/api/alert-policies') return response(policies)
      if (url.pathname === '/api/alert-policies/checkout-burn/evaluation') {
        return response(evaluation('CONDITION_MET', 3.75))
      }
      throw new Error(`Unexpected request: ${url.pathname}`)
    })
    renderPage()

    expect(await screen.findByRole('heading', { name: 'Alert evaluations' })).toBeInTheDocument()
    expect(screen.getByLabelText('Alert evaluation status: Condition met')).toHaveTextContent('CONDITION_MET')
    expect(screen.getAllByText('Burn rate ≥ 2×')).not.toHaveLength(0)
    expect(screen.getByText('3.75×')).toBeInTheDocument()
    expect(screen.getByText('storefront / checkout · production')).toBeInTheDocument()
    expect(screen.getByText('15 minutes')).toBeInTheDocument()
    expect(screen.getByText('Exact half-open interval [from, to)')).toBeInTheDocument()
    expect(screen.getByText(range.from)).toBeInTheDocument()
    expect(screen.getByText(range.to)).toBeInTheDocument()
    expect(screen.getByText('Disabled — not evaluated')).toBeInTheDocument()
    expect(fetchMock.mock.calls.some(([input]) => urlOf(input).pathname.includes('disabled-burn/evaluation'))).toBe(false)

    const investigate = screen.getByRole('link', { name: 'Investigate service' })
    const target = new URL(investigate.getAttribute('href')!, 'http://geordi.test')
    expect(target.pathname).toBe('/investigate')
    expect(target.searchParams.get('serviceName')).toBe('checkout')
    expect(target.searchParams.get('serviceNamespace')).toBe('storefront')
    expect(target.searchParams.get('environment')).toBe('production')
    expect(target.searchParams.get('from')).toBe(range.from)
    expect(target.searchParams.get('to')).toBe(range.to)
  })

  it('renders valid zero as condition not met instead of unavailable', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname === '/api/alert-policies'
      ? response({ alertPolicies: [enabledPolicy] })
      : response(evaluation('CONDITION_NOT_MET', 0)))
    renderPage()

    expect(await screen.findByLabelText('Alert evaluation status: Condition not met')).toHaveTextContent('CONDITION_NOT_MET')
    expect(screen.getByText('0×')).toBeInTheDocument()
    expect(screen.queryByText('Alert evaluation is unavailable.')).not.toBeInTheDocument()
  })

  it.each([
    ['NO_TRAFFIC', 'No traffic was observed in this evaluation window.'],
    ['METRICS_UNAVAILABLE', 'Metrics storage is unavailable for this evaluation.'],
    ['ZERO_ALLOWED_BAD_RATIO', 'Burn rate is unavailable because the referenced objective allows no bad events.'],
  ] as const)('renders %s as unavailable rather than healthy', async (reason, explanation) => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname === '/api/alert-policies'
      ? response({ alertPolicies: [enabledPolicy] })
      : response(evaluation('UNAVAILABLE', null, reason)))
    renderPage()

    expect(await screen.findByLabelText('Alert evaluation status: Unavailable')).toHaveTextContent('UNAVAILABLE')
    expect(screen.getByText(explanation)).toBeInTheDocument()
    expect(screen.getByText('Observed burn rate').nextElementSibling).toHaveTextContent('Unavailable')
  })

  it('preserves exact null namespace semantics in Investigation navigation', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname === '/api/alert-policies'
      ? response({ alertPolicies: [enabledPolicy] })
      : response(evaluation('CONDITION_NOT_MET', 1, null, {
          evidence: { service: { ...service, namespace: null }, window: 'PT15M', range, evaluatedAt: range.to, observedBurnRate: 1 },
        })))
    renderPage()

    const investigate = await screen.findByRole('link', { name: 'Investigate service' })
    const target = new URL(investigate.getAttribute('href')!, 'http://geordi.test')
    expect(target.searchParams.has('serviceNamespace')).toBe(false)
    expect(target.searchParams.get('serviceName')).toBe('checkout')
    expect(target.searchParams.get('environment')).toBe('production')
  })

  it('distinguishes empty and unavailable catalogs from an evaluation failure', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementationOnce(() => response({ alertPolicies: [] }))
    const empty = renderPage()
    expect(await screen.findByRole('heading', { name: 'No alert policies configured' })).toBeInTheDocument()
    empty.unmount()

    vi.restoreAllMocks()
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => response({}, 404))
    const disabled = renderPage()
    expect(await screen.findByRole('heading', { name: 'Alert evaluation is not enabled for this Geordi deployment.' })).toBeInTheDocument()
    disabled.unmount()

    vi.restoreAllMocks()
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname === '/api/alert-policies'
      ? response({ alertPolicies: [enabledPolicy] })
      : response({}, 503))
    renderPage()
    expect(await screen.findByRole('alert')).toHaveTextContent('Alert evaluation is unavailable.')
  })

  it('hides previous status, evidence, and Investigation context while refreshing', async () => {
    const user = userEvent.setup()
    let evaluationCalls = 0
    let resolveRefresh: ((value: Response) => void) | undefined
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const url = urlOf(input)
      if (url.pathname === '/api/alert-policies') return response({ alertPolicies: [enabledPolicy] })
      evaluationCalls += 1
      if (evaluationCalls === 1) return response(evaluation('CONDITION_MET', 4))
      return new Promise<Response>((resolve) => { resolveRefresh = resolve })
    })
    renderPage()

    expect(await screen.findByText('4×')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Refresh evaluations' }))
    expect(await screen.findByText('Refreshing policy and canonical evidence…')).toBeInTheDocument()
    expect(screen.queryByLabelText('Alert evaluation status: Condition met')).not.toBeInTheDocument()
    expect(screen.queryByText('4×')).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Investigate service' })).not.toBeInTheDocument()

    resolveRefresh?.(await response(evaluation('CONDITION_NOT_MET', 1)))
    await waitFor(() => expect(screen.getByLabelText('Alert evaluation status: Condition not met')).toBeInTheDocument())
  })

  it('uses every policy field in the evaluation query key', () => {
    expect(alertEvaluationQueryKey({ ...enabledPolicy, name: 'Changed' })).not.toEqual(alertEvaluationQueryKey(enabledPolicy))
    expect(alertEvaluationQueryKey({ ...enabledPolicy, description: 'Changed' })).not.toEqual(alertEvaluationQueryKey(enabledPolicy))
    expect(alertEvaluationQueryKey({ ...enabledPolicy, enabled: false })).not.toEqual(alertEvaluationQueryKey(enabledPolicy))
    expect(alertEvaluationQueryKey({ ...enabledPolicy, sloId: 'other-slo' })).not.toEqual(alertEvaluationQueryKey(enabledPolicy))
    expect(alertEvaluationQueryKey({ ...enabledPolicy, condition: { ...enabledPolicy.condition, threshold: 5 } })).not.toEqual(alertEvaluationQueryKey(enabledPolicy))
  })

  it('does not render non-finite numbers from an out-of-contract payload', async () => {
    const invalidPolicy = JSON.stringify({ alertPolicies: [enabledPolicy] }).replace('"threshold":2', '"threshold":1e400')
    const invalidEvaluation = JSON.stringify(evaluation('CONDITION_MET', 2))
      .replace('"threshold":2', '"threshold":1e400')
      .replace('"observedBurnRate":2', '"observedBurnRate":1e400')
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => urlOf(input).pathname === '/api/alert-policies'
      ? rawResponse(invalidPolicy)
      : rawResponse(invalidEvaluation))
    renderPage()

    expect(await screen.findByLabelText('Alert evaluation status: Condition met')).toBeInTheDocument()
    expect(screen.getByText('Condition').nextElementSibling).toHaveTextContent('Burn rate ≥ Unavailable')
    expect(screen.getByText('Observed burn rate').nextElementSibling).toHaveTextContent('Unavailable')
    expect(document.body).not.toHaveTextContent(/Infinity|NaN|∞/)
  })
})
