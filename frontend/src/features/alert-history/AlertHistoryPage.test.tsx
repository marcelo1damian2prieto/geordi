import { StrictMode } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, useLocation, useNavigate } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AlertHistoryPage } from './AlertHistoryPage'
import type { AlertEpisode, AlertEpisodeDetailResponse } from '../../api/alertHistory'
import type { AlertEvidence } from '../../api/alertEvaluations'

const a = 'a'.repeat(64)
const b = 'b'.repeat(64)
const from = '2026-08-27T10:00:00.123456789Z'
const to = '2026-08-28T10:00:00.123456789Z'
const base = `from=${from}&to=${to}&limit=50`
const evidence: AlertEvidence = {
  service: { name: 'checkout', namespace: null, environment: 'production' },
  window: 'PT15M', range: { from, to: '2026-08-27T10:15:00.123456789Z' },
  evaluatedAt: '2026-08-27T10:15:00.123456789Z', observedBurnRate: 3,
}
function episode(id = a, policyId = 'checkout-burn', closedAt: string | null = null): AlertEpisode {
  return { id, policyId, openedAt: from, closedAt, origin: 'M14', durationSeconds: closedAt ? 900 : null }
}
function detail(id = a, policyId = 'selected-policy'): AlertEpisodeDetailResponse {
  const evaluation: AlertEpisodeDetailResponse['transitions'][number]['evaluation'] = {
    policyId, policyName: 'Historical policy', sloId: 'availability', condition: { type: 'BURN_RATE_ABOVE', threshold: 2 },
    status: 'CONDITION_MET', reason: null, evidence,
  }
  return {
    episode: episode(id, policyId, evidence.range.to),
    acknowledgement: null,
    transitions: [
      { id: 'resolved', episodeId: id, policyId, type: 'ALERT_RESOLVED', previousState: 'FIRING', currentState: 'INACTIVE', occurredAt: evidence.range.to, evaluation, notification: { disposition: 'SUPPRESSED', delivery: null } },
      { id: 'started', episodeId: id, policyId, type: 'ALERT_STARTED', previousState: 'INACTIVE', currentState: 'FIRING', occurredAt: from, evaluation, notification: { disposition: 'MATCHED', delivery: {
        state: 'PENDING', attempts: 0, createdAt: from, nextAttemptAt: evidence.range.to, completedAt: null,
      } } },
    ],
  }
}
function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': status >= 400 ? 'application/problem+json' : 'application/json' } })
}
function url(input: RequestInfo | URL) {
  return new URL(typeof input === 'string' ? input : input instanceof URL ? input : input.url, 'http://geordi.test')
}
function deferred() {
  let resolve!: (value: Response) => void
  const promise = new Promise<Response>((done) => { resolve = done })
  return { promise, resolve }
}
function Probe() {
  const location = useLocation()
  const navigate = useNavigate()
  return <><output data-testid="location">{location.search}</output>
    <button onClick={() => void navigate(-1)}>Browser Back</button>
    <button onClick={() => void navigate(1)}>Browser Forward</button>
    <button onClick={() => void navigate('/alert-history?from=invalid')}>Invalid bookmark</button>
  </>
}
function renderPage(search = base, strict = false) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, retryDelay: 0, gcTime: 0 } } })
  const content = <QueryClientProvider client={client}><MemoryRouter initialEntries={[`/alert-history?${search}`]}><AlertHistoryPage /><Probe /></MemoryRouter></QueryClientProvider>
  return { ...render(strict ? <StrictMode>{content}</StrictMode> : content), client }
}
function applied() { return new URLSearchParams(screen.getByTestId('location').textContent ?? '') }
function mockSuccess() {
  return vi.spyOn(globalThis, 'fetch').mockImplementation((input) => Promise.resolve(response(
    url(input).pathname === '/api/alert-episodes' ? { alertEpisodes: [episode()] } : detail(),
  )))
}
async function select(id = a) {
  await userEvent.click(await screen.findByRole('link', { name: new RegExp(id) }))
}
afterEach(() => { vi.restoreAllMocks(); vi.useRealTimers() })

describe('Alert history page acceptance', () => {
  it('initializes a direct ID bookmark without bounds while retaining selection', async () => {
    const fetchMock = mockSuccess()
    renderPage(`episodeId=${a}`, true)
    expect(await screen.findByText('selected-policy')).toBeInTheDocument()
    expect(applied().get('episodeId')).toBe(a)
    expect(applied().get('from')).toBeTruthy()
    fetchMock.mock.calls.filter(([input]) => url(input).pathname === '/api/alert-episodes').forEach(([input]) => {
      expect(url(input).searchParams.get('from')).toBe(applied().get('from'))
      expect(url(input).searchParams.get('to')).toBe(applied().get('to'))
    })
  })

  it('All and blank policy remove applied filters, and Back restores the previous URL and form', async () => {
    mockSuccess()
    renderPage(`${base}&policyId=retired&state=CLOSED`)
    const user = userEvent.setup()
    await user.clear(screen.getByLabelText(/Policy ID/i))
    await user.selectOptions(screen.getByLabelText(/^State/i), '')
    await user.click(screen.getByRole('button', { name: 'Apply' }))
    expect(applied().has('policyId')).toBe(false)
    expect(applied().has('state')).toBe(false)
    await user.click(screen.getByRole('button', { name: 'Browser Back' }))
    expect(applied().get('policyId')).toBe('retired')
    expect(screen.getByLabelText(/Policy ID/i)).toHaveValue('retired')
    expect(screen.getByLabelText(/^State/i)).toHaveValue('CLOSED')
  })

  it.each([400, 404])('does not automatically retry HTTP %s for either region', async (status) => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(response({ detail: 'SECRET' }, status))
    renderPage(`${base}&episodeId=${a}`)
    await waitFor(() => expect(screen.getAllByRole('alert')).toHaveLength(2))
    expect(fetchMock.mock.calls.filter(([input]) => url(input).pathname === '/api/alert-episodes')).toHaveLength(1)
    expect(fetchMock.mock.calls.filter(([input]) => url(input).pathname.endsWith(a))).toHaveLength(1)
  })

  it('gives transient failures one automatic retry and falls back safely for non-Problem responses', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation(() => Promise.resolve(new Response('SECRET_HTML', { status: 503, headers: { 'Content-Type': 'text/html' } })))
    renderPage()
    expect(await screen.findByRole('alert')).toHaveTextContent('Alert history is unavailable')
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(document.body.textContent).not.toContain('SECRET_HTML')
  })

  it('labels a detail refresh failure as cached while retaining list and detail', async () => {
    let fail = false
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => Promise.resolve(url(input).pathname === '/api/alert-episodes' ? response({ alertEpisodes: [episode()] }) : fail ? response({}, 503) : response(detail())))
    renderPage(`${base}&episodeId=${a}`)
    await screen.findByText('selected-policy')
    fail = true
    await userEvent.click(screen.getByRole('button', { name: 'Refresh' }))
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(/Refresh failed; showing cached episode detail/))
    expect(screen.getByRole('table')).toBeInTheDocument()
    expect(screen.getByText('selected-policy')).toBeInTheDocument()
  })

  it('invalid draft Apply preserves the bookmark and emits no new request', async () => {
    const fetchMock = mockSuccess()
    renderPage()
    await screen.findByRole('table')
    const count = fetchMock.mock.calls.length
    await userEvent.clear(screen.getByLabelText(/From.*UTC/i))
    await userEvent.type(screen.getByLabelText(/From.*UTC/i), '2026-02-30T00:00:00Z')
    await userEvent.click(screen.getByRole('button', { name: 'Apply' }))
    expect(screen.getByRole('alert')).toBeInTheDocument()
    expect(applied().get('from')).toBe(from)
    expect(fetchMock).toHaveBeenCalledTimes(count)
  })

  it('invalid persisted context leaves readable transitions and the retention notice', async () => {
    const body = structuredClone(detail())
    body.transitions[0].evaluation.evidence!.service.name = ' trimmed '
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => Promise.resolve(response(url(input).pathname === '/api/alert-episodes' ? { alertEpisodes: [] } : body)))
    renderPage(`${base}&episodeId=${a}`)
    expect((await screen.findAllByText('Investigation unavailable for this persisted evidence')).length).toBeGreaterThan(0)
    expect(screen.getByText('RESOLVED')).toBeInTheDocument()
    expect(screen.getByText(/Alert history can outlive source telemetry retention/)).toBeInTheDocument()
  })
  it('anchors one default 24-hour URL before requests under StrictMode and preserves it on reload and refresh', async () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-09-07T12:00:00Z'))
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const request = url(input).searchParams
      expect(request.get('from')).toBe('2026-09-06T12:00:00.000Z')
      expect(request.get('to')).toBe('2026-09-07T12:00:00.000Z')
      expect(applied().get('from')).toBe(request.get('from'))
      return Promise.resolve(response({ alertEpisodes: [] }))
    })
    const first = renderPage('', true)
    await screen.findByText(/No episodes opened in this window match these filters/)
    const anchored = applied().toString()
    vi.setSystemTime(new Date('2026-09-08T12:00:00Z'))
    await userEvent.click(screen.getByRole('button', { name: /^Refresh$/i }))
    expect(applied().toString()).toBe(anchored)
    first.unmount()
    renderPage(anchored)
    await screen.findByText(/No episodes opened in this window match these filters/)
    expect(fetchMock.mock.calls.length).toBeGreaterThanOrEqual(3)
  })

  it('explicit last-24-hours action samples a fresh range and clears selection', async () => {
    mockSuccess()
    vi.useFakeTimers({ toFake: ['Date'] })
    vi.setSystemTime(new Date('2026-09-07T12:00:00Z'))
    renderPage(`${base}&episodeId=${a}`)
    await userEvent.click(screen.getByRole('button', { name: /last 24 hours/i }))
    expect(applied().get('from')).toBe('2026-09-06T12:00:00.000Z')
    expect(applied().get('to')).toBe('2026-09-07T12:00:00.000Z')
    expect(applied().has('episodeId')).toBe(false)
  })

  it.each(['OPEN', 'CLOSED'])('applies %s with exact policy, UTC nanoseconds and limit atomically, clearing detail', async (state) => {
    const fetchMock = mockSuccess()
    const user = userEvent.setup()
    renderPage(`${base}&episodeId=${a}`)
    await screen.findByText('selected-policy')
    await user.type(screen.getByLabelText(/Policy ID/i), 'retired / policy&one')
    await user.selectOptions(screen.getByLabelText(/^State/i), state)
    await user.clear(screen.getByLabelText(/^Limit/i))
    await user.type(screen.getByLabelText(/^Limit/i), '1')
    expect(applied().has('policyId')).toBe(false)
    await user.click(screen.getByRole('button', { name: /^Apply$/i }))
    await waitFor(() => expect(applied().get('state')).toBe(state))
    expect(applied().get('policyId')).toBe('retired / policy&one')
    expect(applied().get('limit')).toBe('1')
    expect(applied().get('from')).toBe(from)
    expect(applied().has('episodeId')).toBe(false)
    await waitFor(() => expect(fetchMock.mock.calls.some(([input]) => url(input).searchParams.get('policyId') === 'retired / policy&one')).toBe(true))
    expect(await screen.findByText(/Showing up to 1 episodes; narrow the filters/)).toBeInTheDocument()
  })

  it('preserves API tie order and exposes semantic labels, table, status and exact timestamps', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(response({ alertEpisodes: [episode(b, 'first-policy'), episode(a, 'second-policy', to)] }))
    renderPage()
    const table = await screen.findByRole('table')
    expect(table.querySelector('caption')).not.toBeNull()
    within(table).getAllByRole('columnheader').forEach((heading) => expect(heading).toHaveAttribute('scope', 'col'))
    const links = within(table).getAllByRole('link')
    expect(links[0]).toHaveAttribute('href', expect.stringContaining(b))
    expect(links[1]).toHaveAttribute('href', expect.stringContaining(a))
    expect(screen.getByText('OPEN — ongoing')).toBeInTheDocument()
    expect(screen.getByText('Not resolved')).toBeInTheDocument()
    expect(screen.getByText(/unavailable while ongoing/i)).toBeInTheDocument()
    expect(within(table).getByText('CLOSED')).toBeInTheDocument()
    expect(table.querySelector('time')).toHaveAttribute('dateTime', from)
    for (const label of [/From.*UTC/i, /To.*UTC/i, /Policy ID/i, /^State/i, /^Limit/i]) {
      expect(screen.getByLabelText(label)).toHaveAttribute('aria-describedby')
    }
    expect(screen.getAllByRole('status').length).toBeGreaterThan(0)
    expect(screen.getByRole('heading', { name: /episodes opened in this window/i })).toBeInTheDocument()
    expect(screen.getByText(/authoritative.*FIRING/i)).toBeInTheDocument()
    expect(screen.getByText(/legacy/i)).toBeInTheDocument()
  })

  it('shows direct detail outside list filters, newest-first transitions and retained evidence links without leaking extra fields', async () => {
    const payload = { ...detail(), destination: 'SECRET_DESTINATION', token: 'SECRET_TOKEN', routing: { payload: 'SECRET_PAYLOAD' } }
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockImplementation((input) => Promise.resolve(response(url(input).pathname === '/api/alert-episodes' ? { alertEpisodes: [] } : payload)))
    renderPage(`${base}&policyId=other-policy&state=OPEN&episodeId=${a}`)
    expect(await screen.findByText('selected-policy')).toBeInTheDocument()
    expect(screen.getByText('Selected episode detail is independent of these list filters.')).toBeInTheDocument()
    expect(screen.getByText(/Alert history can outlive source telemetry retention/)).toBeInTheDocument()
    const resolved = screen.getByText('RESOLVED')
    const started = screen.getByText('STARTED')
    expect(resolved.compareDocumentPosition(started) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    const investigation = screen.getAllByRole('link', { name: /Investigate/i })[0]
    const target = new URL(investigation.getAttribute('href')!, 'http://geordi.test')
    expect(target.pathname).toBe('/investigate')
    expect(target.searchParams.get('from')).toBe(from)
    expect(target.searchParams.get('to')).toBe(evidence.range.to)
    expect(target.searchParams.has('serviceNamespace')).toBe(false)
    expect(document.body.textContent).not.toContain('SECRET_')
    fetchMock.mock.calls.forEach(([input, init]) => {
      expect(init?.method).toBe('GET')
      expect(url(input).pathname).toMatch(/^\/api\/alert-episodes(?:\/[a-f0-9]{64})?$/)
    })
  })

  it('presents bounded notification evidence with truthful delivery state and timestamp fields', async () => {
    const payload = structuredClone(detail())
    const transitions = payload.transitions
    transitions[0].notification = { disposition: 'SUPPRESSED', delivery: null }
    transitions[1].notification = { disposition: 'NOT_RECORDED', delivery: { state: 'LEASED', attempts: 1, createdAt: from, nextAttemptAt: null, completedAt: null } }
    transitions.push({ ...transitions[0], id: 'unrouted', notification: { disposition: 'UNROUTED', delivery: null } })
    transitions.push({ ...transitions[0], id: 'pending', notification: { disposition: 'MATCHED', delivery: { state: 'PENDING', attempts: 0, createdAt: from, nextAttemptAt: evidence.range.to, completedAt: null } } })
    transitions.push({ ...transitions[0], id: 'delivered', notification: { disposition: 'MATCHED', delivery: { state: 'DELIVERED', attempts: 2, createdAt: from, nextAttemptAt: null, completedAt: evidence.range.to } } })
    transitions.push({ ...transitions[0], id: 'failed', notification: { disposition: 'MATCHED', delivery: { state: 'FAILED', attempts: 3, createdAt: from, nextAttemptAt: null, completedAt: evidence.range.to } } })
    const secret = 'SECRET_DELIVERY_INTERNAL'
    ;(payload as unknown as Record<string, unknown>).destination = secret
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => Promise.resolve(response(url(input).pathname === '/api/alert-episodes' ? { alertEpisodes: [] } : payload)))
    renderPage(`${base}&episodeId=${a}`)
    expect((await screen.findAllByText('Matched')).length).toBeGreaterThan(0)
    expect(screen.getByText('Suppressed')).toBeInTheDocument()
    expect(screen.getByText('No matching route')).toBeInTheDocument()
    expect(screen.getByText('Not recorded')).toBeInTheDocument()
    expect(screen.getByText('Leased — completion not recorded; may await reclaim')).toBeInTheDocument()
    expect(screen.getByText('Pending')).toBeInTheDocument()
    expect(screen.getByText('Delivered — Geordi recorded an accepted HTTP response')).toBeInTheDocument()
    expect(screen.getByText('Failed — no detailed cause was recorded')).toBeInTheDocument()
    expect(screen.getAllByText('Claims consumed')).toHaveLength(4)
    expect(screen.getAllByText('Next attempt (UTC)')).toHaveLength(1)
    expect(screen.getAllByText('Completed (UTC)')).toHaveLength(2)
    expect(document.body.textContent).not.toContain(secret)
  })

  it('supports known-ID legacy detail honestly without inventing a ranged legacy row', async () => {
    const legacy = { episode: { ...episode(a, 'legacy-policy', to), openedAt: null, durationSeconds: null, origin: 'PRE_M14_UNKNOWN_START' }, transitions: [] }
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => Promise.resolve(response(url(input).pathname === '/api/alert-episodes' ? { alertEpisodes: [] } : legacy)))
    renderPage(`${base}&episodeId=${a}`)
    expect(await screen.findByText('CLOSED — legacy, start unknown')).toBeInTheDocument()
    expect(screen.getByText('Start unavailable')).toBeInTheDocument()
    expect(screen.getByText('Duration unavailable')).toBeInTheDocument()
    expect(screen.getByText(/No episodes opened in this window match these filters/)).toBeInTheDocument()
  })

  it.each(['from=bad', `from=${to}&to=${from}`, `${base}&state=UNKNOWN`, `${base}&limit=0`, `${base}&episodeId=ABC`, `${base}&state=OPEN&state=CLOSED`])('invalid bookmark %s blocks all requests and exposes editable validation and reset', async (search) => {
    const fetchMock = mockSuccess()
    renderPage(search)
    expect(await screen.findByRole('alert')).toBeInTheDocument()
    expect(document.querySelector('[aria-invalid="true"]')).not.toBeNull()
    expect(fetchMock).not.toHaveBeenCalled()
    expect(screen.getByTestId('location')).toHaveTextContent(search)
    await userEvent.click(screen.getByRole('button', { name: /Reset to last 24 hours/i }))
    await waitFor(() => expect(fetchMock).toHaveBeenCalled())
    expect(applied().has('episodeId')).toBe(false)
    expect(applied().has('state')).toBe(false)
  })

  it.each([[400, 'Invalid alert history request'], [404, 'Alert history is unavailable or disabled'], [503, 'unavailable']])('list HTTP %s is bounded and leaves successful detail intact', async (status, message) => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => Promise.resolve(url(input).pathname === '/api/alert-episodes' ? response({ detail: 'SECRET_EXCEPTION', title: 'SECRET_TOKEN' }, status) : response(detail())))
    renderPage(`${base}&episodeId=${a}`)
    expect(await screen.findByText('selected-policy')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(new RegExp(message, 'i')))
    expect(document.body.textContent).not.toContain('SECRET_')
    expect(screen.getByLabelText(/From.*UTC/i)).toBeEnabled()
  })

  it('detail 404 preserves the valid list and permits closing', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => Promise.resolve(url(input).pathname === '/api/alert-episodes' ? response({ alertEpisodes: [episode()] }) : response({}, 404)))
    renderPage(`${base}&episodeId=${a}`)
    expect(await screen.findByText(/Episode not found or history unavailable/i)).toBeInTheDocument()
    expect(screen.getByRole('table')).toHaveTextContent('checkout-burn')
    await userEvent.click(screen.getByRole('button', { name: /Close.*detail/i }))
    expect(applied().has('episodeId')).toBe(false)
  })

  it('network failure has an accessible manual retry that recovers without shifting the range', async () => {
    let fail = true
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => fail ? Promise.reject(new Error('SECRET_NETWORK')) : Promise.resolve(response({ alertEpisodes: [episode()] })))
    renderPage()
    expect(await screen.findByRole('alert')).toHaveTextContent(/unavailable/i)
    expect(document.body.textContent).not.toContain('SECRET_NETWORK')
    fail = false
    await userEvent.click(screen.getByRole('button', { name: /Retry/i }))
    expect(await screen.findByRole('table')).toHaveTextContent('checkout-burn')
    expect(applied().get('from')).toBe(from)
  })

  it('failed same-key refresh is explicitly labeled', async () => {
    let fail = false
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => Promise.resolve(fail ? response({}, 503) : response({ alertEpisodes: [episode()] })))
    renderPage()
    await screen.findByRole('table')
    fail = true
    await userEvent.click(screen.getByRole('button', { name: /^Refresh$/i }))
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(/refresh/i))
    if (screen.queryByRole('table')) expect(screen.getByRole('alert')).toHaveTextContent(/cached/i)
  })

  it('ignores late list A after filter B resolves, even when transport ignores abort', async () => {
    const pendingA = deferred()
    const pendingB = deferred()
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => url(input).searchParams.get('policyId') === 'B' ? pendingB.promise : pendingA.promise)
    renderPage(`${base}&policyId=A`)
    const user = userEvent.setup()
    await user.clear(screen.getByLabelText(/Policy ID/i))
    await user.type(screen.getByLabelText(/Policy ID/i), 'B')
    await user.click(screen.getByRole('button', { name: /^Apply$/i }))
    await act(async () => { pendingB.resolve(response({ alertEpisodes: [episode(b, 'response-B')] })); await pendingB.promise })
    expect(await screen.findByText('response-B')).toBeInTheDocument()
    await act(async () => { pendingA.resolve(response({ alertEpisodes: [episode(a, 'response-A')] })); await pendingA.promise })
    expect(screen.queryByText('response-A')).not.toBeInTheDocument()
    expect(screen.getByText('response-B')).toBeInTheDocument()
  })

  it('ignores late detail A after B resolves and clears detail for invalid URL', async () => {
    const pendingA = deferred()
    const pendingB = deferred()
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => {
      const path = url(input).pathname
      return path.endsWith(`/${a}`) ? pendingA.promise : path.endsWith(`/${b}`) ? pendingB.promise : Promise.resolve(response({ alertEpisodes: [episode(a), episode(b)] }))
    })
    renderPage()
    await select(a)
    await select(b)
    await act(async () => { pendingB.resolve(response(detail(b, 'detail-B'))); await pendingB.promise })
    expect(await screen.findByText('detail-B')).toBeInTheDocument()
    await act(async () => { pendingA.resolve(response(detail(a, 'detail-A'))); await pendingA.promise })
    expect(screen.queryByText('detail-A')).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Invalid bookmark' }))
    expect(await screen.findByRole('alert')).toBeInTheDocument()
    expect(screen.queryByText('detail-B')).not.toBeInTheDocument()
  })

  it('keyboard selection focuses the stable detail heading once, marks current, closes to initiating link and supports Back/Forward', async () => {
    const pending = deferred()
    vi.spyOn(globalThis, 'fetch').mockImplementation((input) => url(input).pathname === '/api/alert-episodes' ? Promise.resolve(response({ alertEpisodes: [episode()] })) : pending.promise)
    renderPage()
    const user = userEvent.setup()
    const link = await screen.findByRole('link', { name: new RegExp(a) })
    link.focus()
    await user.keyboard('{Enter}')
    await waitFor(() => expect(document.activeElement?.tagName).toMatch(/^H[1-6]$/))
    expect(document.activeElement).toHaveAttribute('tabindex', '-1')
    expect(link).toHaveAttribute('aria-current')
    const close = screen.getByRole('button', { name: /Close.*detail/i })
    close.focus()
    await act(async () => { pending.resolve(response(detail())); await pending.promise })
    await screen.findByText('selected-policy')
    expect(close).toHaveFocus()
    await user.click(close)
    expect(link).toHaveFocus()
    expect(applied().has('episodeId')).toBe(false)
    await user.click(screen.getByRole('button', { name: 'Browser Back' }))
    await waitFor(() => expect(applied().get('episodeId')).toBe(a))
    expect(screen.getByRole('button', { name: 'Browser Back' })).toHaveFocus()
    await user.click(screen.getByRole('button', { name: 'Browser Forward' }))
    expect(applied().has('episodeId')).toBe(false)
  })

  it('closing a direct bookmark falls back to the list heading without bookmark focus stealing', async () => {
    mockSuccess()
    renderPage(`${base}&episodeId=${b}`)
    await screen.findByText('selected-policy')
    expect(document.activeElement).toBe(document.body)
    await userEvent.click(screen.getByRole('button', { name: /Close.*detail/i }))
    expect(document.activeElement?.tagName).toMatch(/^H[1-6]$/)
    expect(document.activeElement).toHaveTextContent(/episodes/i)
  })
})
