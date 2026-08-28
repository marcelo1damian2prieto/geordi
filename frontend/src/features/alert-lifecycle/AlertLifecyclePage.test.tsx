import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { AlertEvaluation, AlertPolicy } from '../../api/alertEvaluations'
import type {
  AlertLifecycleEvaluationResult,
  AlertLifecycleSnapshot,
  AlertTransition,
} from '../../api/alertLifecycles'
import { AlertLifecyclePage } from './AlertLifecyclePage'
import { alertLifecyclePolicyKey } from './useAlertLifecycles'

const policy: AlertPolicy = {
  id: 'checkout-burn',
  name: 'Checkout burn',
  description: 'Current checkout availability burn.',
  enabled: true,
  sloId: 'checkout-availability',
  condition: { type: 'BURN_RATE_ABOVE', threshold: 2 },
}
const service = { name: 'checkout', namespace: 'storefront', environment: 'production' }
const range = { from: '2026-08-27T10:00:00.000Z', to: '2026-08-27T10:15:00.000Z' }
const previousRange = { from: '2026-08-27T09:45:00.000Z', to: '2026-08-27T10:00:00.000Z' }

function evaluation(
  status: AlertEvaluation['status'],
  observedBurnRate: number | null,
  reason: AlertEvaluation['reason'] = null,
  evidenceRange = range,
): AlertEvaluation {
  return {
    policyId: policy.id,
    policyName: policy.name,
    sloId: policy.sloId,
    condition: policy.condition,
    status,
    reason,
    evidence: {
      service,
      window: 'PT15M',
      range: evidenceRange,
      evaluatedAt: evidenceRange.to,
      observedBurnRate,
    },
  }
}

function snapshot(overrides: Partial<AlertLifecycleSnapshot> = {}): AlertLifecycleSnapshot {
  return {
    policy,
    initialized: false,
    state: 'INACTIVE',
    latestEvaluation: null,
    activeEvidence: null,
    startedAt: null,
    resolvedAt: null,
    lastStateChangeAt: null,
    lastProcessedAt: null,
    lastEvidenceAt: null,
    latestTransition: null,
    ...overrides,
  }
}

function transition(
  type: AlertTransition['type'],
  triggeringEvaluation: AlertEvaluation,
): AlertTransition {
  return {
    policyId: policy.id,
    type,
    previousState: type === 'ALERT_STARTED' ? 'INACTIVE' : 'FIRING',
    currentState: type === 'ALERT_STARTED' ? 'FIRING' : 'INACTIVE',
    occurredAt: triggeringEvaluation.evidence?.evaluatedAt ?? range.to,
    evaluation: triggeringEvaluation,
  }
}

function result(
  triggeringEvaluation: AlertEvaluation,
  current: AlertLifecycleSnapshot,
  lifecycleTransition: AlertTransition | null,
  outcome: AlertLifecycleEvaluationResult['outcome'] = 'APPLIED',
): AlertLifecycleEvaluationResult {
  return { triggeringEvaluation, outcome, current, transition: lifecycleTransition }
}

function json(body: unknown, status = 200) {
  return Promise.resolve(new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': status >= 400 ? 'application/problem+json' : 'application/json' },
  }))
}

function renderPage() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter><AlertLifecyclePage /></MemoryRouter>
    </QueryClientProvider>,
  )
}

function requestPath(input: RequestInfo | URL) {
  return new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test').pathname
}

afterEach(() => vi.restoreAllMocks())

describe('Alert lifecycle', () => {
  it('loads state without causing an evaluation and explains an uninitialized inactive policy', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation((_input, init) => {
      expect(init?.method).toBe('GET')
      return json({ alertStates: [snapshot()] })
    })
    renderPage()

    expect(screen.getByText('Loading alert lifecycle states…')).toHaveAttribute('aria-busy', 'true')
    expect(await screen.findByRole('heading', { name: 'Alert lifecycle' })).toBeInTheDocument()
    expect(screen.getByLabelText('Alert lifecycle state: Inactive')).toHaveTextContent('INACTIVE')
    expect(screen.getByText('No lifecycle evaluation recorded. The initial state is INACTIVE.')).toBeInTheDocument()
    expect(screen.getByText('No condition evaluation has been processed.')).toBeInTheDocument()
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(requestPath(fetchMock.mock.calls[0][0])).toBe('/api/alert-states')
  })

  it('applies a first condition-met evaluation and shows one explicit started transition', async () => {
    const user = userEvent.setup()
    const met = evaluation('CONDITION_MET', 3.5)
    const started = transition('ALERT_STARTED', met)
    const firing = snapshot({
      initialized: true,
      state: 'FIRING',
      latestEvaluation: met,
      activeEvidence: met.evidence,
      startedAt: range.to,
      lastStateChangeAt: range.to,
      lastProcessedAt: range.to,
      lastEvidenceAt: range.to,
      latestTransition: started,
    })
    vi.spyOn(globalThis, 'fetch').mockImplementation((_input, init) => init?.method === 'POST'
      ? json(result(met, firing, started))
      : json({ alertStates: [snapshot()] }))
    renderPage()

    await user.click(await screen.findByRole('button', { name: 'Evaluate now' }))
    expect(await screen.findByLabelText('Alert lifecycle state: Firing')).toHaveTextContent('FIRING')
    expect(screen.getByLabelText('Latest evaluation status: Condition met')).toHaveTextContent('CONDITION_MET')
    expect(screen.getByText('This evaluation produced alert started.')).toBeInTheDocument()
    expect(screen.getByText('ALERT_STARTED')).toBeInTheDocument()
    expect(screen.getByText('Started at').nextElementSibling?.querySelector('time')).toHaveAttribute('dateTime', range.to)
  })

  it('keeps a repeated condition-met evaluation firing without a repeated transition', async () => {
    const user = userEvent.setup()
    const first = evaluation('CONDITION_MET', 3, null, previousRange)
    const repeated = evaluation('CONDITION_MET', 4)
    const firing = snapshot({ initialized: true, state: 'FIRING', latestEvaluation: first, activeEvidence: first.evidence, startedAt: previousRange.to, lastProcessedAt: previousRange.to, lastEvidenceAt: previousRange.to })
    const continued = { ...firing, latestEvaluation: repeated, activeEvidence: repeated.evidence, lastProcessedAt: range.to, lastEvidenceAt: range.to }
    vi.spyOn(globalThis, 'fetch').mockImplementation((_input, init) => init?.method === 'POST'
      ? json(result(repeated, continued, null))
      : json({ alertStates: [firing] }))
    renderPage()

    await user.click(await screen.findByRole('button', { name: 'Evaluate now' }))
    expect(await screen.findByText('Evaluation applied. Lifecycle state did not change.')).toBeInTheDocument()
    expect(screen.getByText('Started at').nextElementSibling?.querySelector('time')).toHaveAttribute('dateTime', previousRange.to)
    expect(screen.queryByText('This evaluation produced alert started.')).not.toBeInTheDocument()
  })

  it('shows a valid resolution and does not fabricate another resolution for repeated not-met evidence', async () => {
    const user = userEvent.setup()
    const met = evaluation('CONDITION_MET', 3, null, previousRange)
    const notMet = evaluation('CONDITION_NOT_MET', 1)
    const resolvedTransition = transition('ALERT_RESOLVED', notMet)
    const firing = snapshot({ initialized: true, state: 'FIRING', latestEvaluation: met, activeEvidence: met.evidence, startedAt: previousRange.to, lastProcessedAt: previousRange.to, lastEvidenceAt: previousRange.to })
    const inactive = snapshot({ initialized: true, state: 'INACTIVE', latestEvaluation: notMet, resolvedAt: range.to, lastStateChangeAt: range.to, lastProcessedAt: range.to, lastEvidenceAt: range.to, latestTransition: resolvedTransition })
    let postCalls = 0
    vi.spyOn(globalThis, 'fetch').mockImplementation((_input, init) => {
      if (init?.method !== 'POST') return json({ alertStates: [firing] })
      postCalls += 1
      return postCalls === 1
        ? json(result(notMet, inactive, resolvedTransition))
        : json(result(notMet, inactive, null, 'DUPLICATE_IGNORED'))
    })
    renderPage()

    await user.click(await screen.findByRole('button', { name: 'Evaluate now' }))
    expect(await screen.findByText('This evaluation produced alert resolved.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Evaluate now' }))
    expect(await screen.findByText('Duplicate evidence was ignored. Lifecycle state did not change.')).toBeInTheDocument()
    expect(screen.getByLabelText('Alert lifecycle state: Inactive')).toBeInTheDocument()
  })

  it('keeps firing on unavailable evidence and investigates retained firing evidence', async () => {
    const met = evaluation('CONDITION_MET', 3, null, previousRange)
    const unavailable = evaluation('UNAVAILABLE', null, 'METRICS_UNAVAILABLE')
    const firing = snapshot({
      initialized: true,
      state: 'FIRING',
      latestEvaluation: unavailable,
      activeEvidence: met.evidence,
      startedAt: previousRange.to,
      lastProcessedAt: range.to,
      lastEvidenceAt: range.to,
    })
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => json({ alertStates: [firing] }))
    renderPage()

    expect(await screen.findByText('Current evidence is unavailable. Lifecycle state remains FIRING.')).toBeInTheDocument()
    expect(screen.getByText('Metrics storage is unavailable for this evaluation.')).toBeInTheDocument()
    expect(screen.queryByText(/alert resolved/i)).not.toBeInTheDocument()
    expect(screen.queryByText('ALERT_RESOLVED')).not.toBeInTheDocument()
    const target = new URL(screen.getByRole('link', { name: 'Investigate retained firing evidence' }).getAttribute('href')!, 'http://geordi.test')
    expect(target.searchParams.get('from')).toBe(previousRange.from)
    expect(target.searchParams.get('to')).toBe(previousRange.to)
  })

  it('does not imply activation for inactive unavailable evidence', async () => {
    const unavailable = evaluation('UNAVAILABLE', null, 'NO_TRAFFIC')
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => json({ alertStates: [snapshot({ initialized: true, latestEvaluation: unavailable, lastProcessedAt: range.to, lastEvidenceAt: range.to })] }))
    renderPage()

    expect(await screen.findByText('Current evidence is unavailable. No alert was started.')).toBeInTheDocument()
    expect(screen.getByLabelText('Alert lifecycle state: Inactive')).toBeInTheDocument()
  })

  it('shows a disabled firing policy as frozen with retained evidence and no command', async () => {
    const disabledPolicy = { ...policy, enabled: false }
    const met = evaluation('CONDITION_MET', 3, null, previousRange)
    const disabledFiring = snapshot({ policy: disabledPolicy, initialized: true, state: 'FIRING', latestEvaluation: null, activeEvidence: met.evidence, startedAt: previousRange.to, lastProcessedAt: range.to, lastEvidenceAt: previousRange.to })
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(() => json({ alertStates: [disabledFiring] }))
    renderPage()

    expect(await screen.findByText('Policy disabled — lifecycle state is frozen as FIRING. Disabling does not indicate recovery.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Evaluate now' })).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Investigate retained firing evidence' })).toBeInTheDocument()
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('renders valid zero and preserves exact null-namespace Investigation context', async () => {
    const zero = evaluation('CONDITION_NOT_MET', 0)
    zero.evidence = { ...zero.evidence!, service: { ...service, namespace: null } }
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => json({ alertStates: [snapshot({ initialized: true, latestEvaluation: zero, lastProcessedAt: range.to, lastEvidenceAt: range.to })] }))
    renderPage()

    expect(await screen.findAllByText('0×')).toHaveLength(2)
    const target = new URL(screen.getByRole('link', { name: 'Investigate latest evaluated window' }).getAttribute('href')!, 'http://geordi.test')
    expect(target.searchParams.has('serviceNamespace')).toBe(false)
    expect(target.searchParams.get('serviceName')).toBe(service.name)
    expect(target.searchParams.get('environment')).toBe(service.environment)
    expect(target.searchParams.get('from')).toBe(range.from)
    expect(target.searchParams.get('to')).toBe(range.to)
  })

  it('shows read failures distinctly and hides stale state, timestamps, and links while refreshing', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValueOnce(new Response('', { status: 503 }))
    const failed = renderPage()
    expect(await screen.findByRole('heading', { name: 'Alert lifecycle state is unavailable.' })).toBeInTheDocument()
    failed.unmount()

    vi.restoreAllMocks()
    const user = userEvent.setup()
    const met = evaluation('CONDITION_MET', 3)
    const firing = snapshot({ initialized: true, state: 'FIRING', latestEvaluation: met, activeEvidence: met.evidence, startedAt: range.to, lastProcessedAt: range.to, lastEvidenceAt: range.to })
    let resolveRefresh: ((response: Response) => void) | undefined
    let calls = 0
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => {
      calls += 1
      if (calls === 1) return json({ alertStates: [firing] })
      return new Promise<Response>((resolve) => { resolveRefresh = resolve })
    })
    renderPage()
    expect(await screen.findByLabelText('Alert lifecycle state: Firing')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Refresh states' }))
    expect(await screen.findByText('Refreshing current lifecycle states…')).toBeInTheDocument()
    expect(screen.queryByLabelText('Alert lifecycle state: Firing')).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /Investigate/ })).not.toBeInTheDocument()
    expect(screen.queryByText(range.from)).not.toBeInTheDocument()
    resolveRefresh?.(await json({ alertStates: [snapshot()] }))
    expect(await screen.findByLabelText('Alert lifecycle state: Inactive')).toBeInTheDocument()
  })

  it('includes every policy field in the command key', () => {
    expect(alertLifecyclePolicyKey({ ...policy, name: 'Changed' })).not.toEqual(alertLifecyclePolicyKey(policy))
    expect(alertLifecyclePolicyKey({ ...policy, description: 'Changed' })).not.toEqual(alertLifecyclePolicyKey(policy))
    expect(alertLifecyclePolicyKey({ ...policy, enabled: false })).not.toEqual(alertLifecyclePolicyKey(policy))
    expect(alertLifecyclePolicyKey({ ...policy, sloId: 'another-slo' })).not.toEqual(alertLifecyclePolicyKey(policy))
    expect(alertLifecyclePolicyKey({ ...policy, condition: { ...policy.condition, threshold: 5 } })).not.toEqual(alertLifecyclePolicyKey(policy))
  })

  it('hides the prior snapshot and prevents overlapping commands while evaluating', async () => {
    const user = userEvent.setup()
    const met = evaluation('CONDITION_MET', 3)
    const firing = snapshot({ initialized: true, state: 'FIRING', latestEvaluation: met, activeEvidence: met.evidence, startedAt: range.to, lastProcessedAt: range.to, lastEvidenceAt: range.to })
    let resolveCommand: ((response: Response) => void) | undefined
    vi.spyOn(globalThis, 'fetch').mockImplementation((_input, init) => init?.method === 'POST'
      ? new Promise<Response>((resolve) => { resolveCommand = resolve })
      : json({ alertStates: [firing] }))
    renderPage()

    const command = await screen.findByRole('button', { name: 'Evaluate now' })
    await user.click(command)
    expect(await screen.findByText('Evaluating canonical evidence and applying lifecycle state…')).toBeInTheDocument()
    expect(screen.queryByLabelText('Alert lifecycle state: Firing')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Evaluate now' })).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /Investigate/ })).not.toBeInTheDocument()
    resolveCommand?.(await json(result(met, firing, null)))
    await waitFor(() => expect(screen.getByRole('button', { name: 'Evaluate now' })).toBeInTheDocument())
  })
})
