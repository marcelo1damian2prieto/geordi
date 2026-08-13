import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, getJson } from './client'

afterEach(() => vi.restoreAllMocks())

describe('Geordi API client', () => {
  it('retains RFC problem details for explicit error handling', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response(JSON.stringify({
      type: 'https://geordi.dev/problems/trace-not-found',
      title: 'Trace not found',
      status: 404,
      detail: 'No trace exists for the requested identifier.',
    }), { status: 404, headers: { 'Content-Type': 'application/problem+json' } }))

    await expect(getJson('/api/traces/abc')).rejects.toMatchObject({
      status: 404,
      problem: { title: 'Trace not found' },
    } satisfies Partial<ApiError>)
  })

  it('handles non-problem error bodies without creating an unhandled parse error', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('', { status: 503 }))

    await expect(getJson('/api/traces')).rejects.toMatchObject({ status: 503, problem: undefined })
  })
})
