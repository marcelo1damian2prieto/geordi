import { afterEach, describe, expect, it, vi } from 'vitest'
import { getServiceMap, type ServiceMapResponse } from './serviceMap'

const fixture = {
  context: {
    environment: 'development',
    range: { from: '2026-08-20T10:00:00.000Z', to: '2026-08-20T11:00:00.000Z' },
  },
  nodes: [
    { name: 'checkout', namespace: 'storefront', environment: 'development' },
    { name: 'checkout', namespace: 'fulfillment', environment: 'development' },
  ],
  edges: [{
    caller: { name: 'checkout', namespace: 'storefront', environment: 'development' },
    callee: { name: 'checkout', namespace: 'fulfillment', environment: 'development' },
    evidenceCount: 2,
    evidence: [
      { traceId: 'a'.repeat(32), observedAt: '2026-08-20T10:12:00.000Z' },
      { traceId: 'b'.repeat(32), observedAt: '2026-08-20T10:18:00.000Z' },
    ],
  }],
  truncated: false,
} satisfies ServiceMapResponse

afterEach(() => vi.restoreAllMocks())

describe('Service Map API', () => {
  it('requests the exact environment and absolute half-open range', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify(fixture), { status: 200 }))

    await expect(getServiceMap(fixture.context.environment, fixture.context.range)).resolves.toEqual(fixture)

    const target = new URL(fetchMock.mock.calls[0][0] as string, 'http://geordi.test')
    expect(target.pathname).toBe('/api/service-map')
    expect(target.searchParams.get('environment')).toBe('development')
    expect(target.searchParams.get('from')).toBe(fixture.context.range.from)
    expect(target.searchParams.get('to')).toBe(fixture.context.range.to)
  })
})
