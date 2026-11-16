import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiError, clearCsrfToken, getJson, invalidateAuthentication, markAuthenticationValidated, postJson, resolveApiBaseUrl } from './client'

afterEach(() => { vi.restoreAllMocks(); clearCsrfToken(); markAuthenticationValidated() })

describe('Geordi API client', () => {
  it('accepts only a same-origin HTTPS API base URL', () => {
    expect(resolveApiBaseUrl(undefined, 'https://geordi.localhost:8443')).toBe('')
    expect(resolveApiBaseUrl('https://geordi.localhost:8443/', 'https://geordi.localhost:8443'))
      .toBe('https://geordi.localhost:8443')
    expect(() => resolveApiBaseUrl('http://geordi.localhost:8443', 'https://geordi.localhost:8443'))
      .toThrow('VITE_API_BASE_URL must be a same-origin HTTPS URL')
    expect(() => resolveApiBaseUrl('https://attacker.example', 'https://geordi.localhost:8443'))
      .toThrow('VITE_API_BASE_URL must be a same-origin HTTPS URL')
  })

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

  it('obtains and sends the in-memory session CSRF token on mutations', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response(JSON.stringify({ headerName: 'X-CSRF-TOKEN', token: 'csrf-test-token' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true }), {
        status: 201, headers: { 'Content-Type': 'application/json' },
      }))

    await expect(postJson<{ ok: boolean }>('/api/example', { value: 1 })).resolves.toEqual({ ok: true })
    expect(fetchMock).toHaveBeenCalledTimes(2)
    expect(fetchMock.mock.calls[0]?.[0]).toBe('/api/auth/csrf')
    expect(fetchMock.mock.calls[1]?.[1]).toMatchObject({
      credentials: 'same-origin',
      headers: { 'X-CSRF-TOKEN': 'csrf-test-token' },
    })
  })

  it('handles a no-content logout response', async () => {
    vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response(JSON.stringify({ headerName: 'X-CSRF-TOKEN', token: 'csrf-test-token' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))

    await expect(postJson<void>('/api/auth/logout')).resolves.toBeUndefined()
  })

  it('blocks further mutations after a rejected session until identity is revalidated', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(new Response(JSON.stringify({ headerName: 'X-CSRF-TOKEN', token: 'csrf-old' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response('', { status: 403 }))

    await expect(postJson('/api/alert-episodes/example/acknowledgements')).rejects.toMatchObject({ status: 403 })
    await expect(postJson('/api/alert-episodes/example/acknowledgements')).rejects.toMatchObject({ status: 401 })
    expect(fetchMock).toHaveBeenCalledTimes(2)

    markAuthenticationValidated()
    fetchMock
      .mockResolvedValueOnce(new Response(JSON.stringify({ headerName: 'X-CSRF-TOKEN', token: 'csrf-new' }), {
        status: 200, headers: { 'Content-Type': 'application/json' },
      }))
      .mockResolvedValueOnce(new Response(null, { status: 204 }))
    await expect(postJson('/api/alert-episodes/example/acknowledgements')).resolves.toBeUndefined()
  })

  it('invalidates authentication when the first CSRF bootstrap expires', async () => {
    const authInvalidated = vi.fn()
    window.addEventListener('geordi:auth-invalidated', authInvalidated)
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(new Response('', { status: 401 }))
    try {
      await expect(postJson('/api/alert-episodes/example/acknowledgements')).rejects.toMatchObject({ status: 401 })
      expect(authInvalidated).toHaveBeenCalledOnce()
      await expect(postJson('/api/alert-episodes/example/acknowledgements')).rejects.toMatchObject({ status: 401 })
    } finally {
      window.removeEventListener('geordi:auth-invalidated', authInvalidated)
    }
  })

  it('discards API responses that complete after the principal generation changes', async () => {
    let complete!: (response: Response) => void
    vi.spyOn(globalThis, 'fetch').mockImplementation(() => new Promise((resolve) => { complete = resolve }))
    const pending = getJson('/api/platform')
    invalidateAuthentication()
    complete(new Response(JSON.stringify({ stale: true }), {
      status: 200, headers: { 'Content-Type': 'application/json' },
    }))
    await expect(pending).rejects.toMatchObject({ status: 401 })
  })
})
