import { afterEach, describe, expect, it, vi } from 'vitest'
import { getAlertEpisode, listAlertEpisodes } from './alertHistory'
import type { AlertEpisodeDetailResponse } from './alertHistory'
import { ApiError } from './client'

afterEach(() => vi.unstubAllGlobals())
describe('alert history read client', () => {
  it('encodes GET filters verbatim, preserves nanoseconds/nulls and forwards abort', async () => {
    const body = { alertEpisodes: [{ id: 'a', openedAt: null, closedAt: '2026-09-07T12:00:00.123456789Z', durationSeconds: null }] }
    const fetcher = vi.fn().mockResolvedValue(new Response(JSON.stringify(body)))
    vi.stubGlobal('fetch', fetcher)
    const signal = new AbortController().signal
    const query = { from: '2026-09-06T12:00:00.123456789Z', to: '2026-09-07T12:00:00.123456789Z', policyId: 'a /?&+=é', state: 'OPEN' as const, limit: 50 }
    expect(await listAlertEpisodes(query, signal)).toEqual(body)
    const [url, options] = fetcher.mock.calls[0] as [string, RequestInit]
    expect(Object.fromEntries(new URL(url, 'http://local').searchParams)).toEqual({ ...query, limit: '50' })
    expect(options).toMatchObject({ method: 'GET', signal })
  })
  it('encodes detail ID and preserves the detail envelope', async () => {
    const body: AlertEpisodeDetailResponse = { episode: { id: 'episode', policyId: 'policy', openedAt: null, closedAt: null, origin: 'M14', durationSeconds: null }, acknowledgement: null, transitions: [{
      id: 'transition', episodeId: 'episode', policyId: 'policy', type: 'ALERT_STARTED', previousState: 'INACTIVE', currentState: 'FIRING', occurredAt: '2026-01-01T00:00:00Z',
      evaluation: { policyId: 'policy', policyName: 'Policy', sloId: 'slo', condition: { type: 'BURN_RATE_ABOVE', threshold: 2 }, status: 'CONDITION_MET', reason: null, evidence: null },
      notification: { disposition: 'MATCHED', delivery: { state: 'PENDING', attempts: 0, createdAt: '2026-01-01T00:00:00Z', nextAttemptAt: '2026-01-01T00:01:00Z', completedAt: null } },
    }] }
    const fetcher = vi.fn().mockResolvedValue(new Response(JSON.stringify(body)))
    vi.stubGlobal('fetch', fetcher)
    const signal = new AbortController().signal
    expect(await getAlertEpisode('a /?', signal)).toEqual(body)
    expect(fetcher).toHaveBeenCalledWith('/api/alert-episodes/a%20%2F%3F', expect.objectContaining({ method: 'GET', signal }))
  })
  it.each([['application/problem+json', '{"title":"Invalid","status":400}', { title: 'Invalid', status: 400 }], ['application/problem+json', '{bad', undefined], ['text/html', 'private failure', undefined]])('reuses bounded ApiError for %s', async (contentType, body, problem) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(body, { status: 400, headers: { 'Content-Type': contentType } })))
    const failure = await getAlertEpisode('a').catch((error: unknown) => error)
    expect(failure).toBeInstanceOf(ApiError)
    expect(failure).toMatchObject({ status: 400, problem })
  })
})
