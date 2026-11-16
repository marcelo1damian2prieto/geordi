const configuredBaseUrl: unknown = import.meta.env.VITE_API_BASE_URL

export function resolveApiBaseUrl(configured: unknown, pageOrigin: string): string {
  if (configured === undefined || configured === null || configured === '') return ''
  if (typeof configured !== 'string') throw new Error('VITE_API_BASE_URL must be a same-origin HTTPS URL')
  let base: URL
  let page: URL
  try {
    base = new URL(configured, pageOrigin)
    page = new URL(pageOrigin)
  } catch {
    throw new Error('VITE_API_BASE_URL must be a same-origin HTTPS URL')
  }
  if (base.protocol !== 'https:' || page.protocol !== 'https:' || base.origin !== page.origin ||
    base.pathname !== '/' || base.search !== '' || base.hash !== '' || base.username !== '' || base.password !== '') {
    throw new Error('VITE_API_BASE_URL must be a same-origin HTTPS URL')
  }
  return /^https:\/\//i.test(configured) ? base.origin : ''
}

const apiBaseUrl = resolveApiBaseUrl(
  configuredBaseUrl,
  typeof window === 'undefined' ? '' : window.location.origin,
)

let csrfToken: string | undefined
let csrfRequest: Promise<string> | undefined
let authenticationInvalidated = false
let authenticationGeneration = 0

interface CsrfResponse { headerName: 'X-CSRF-TOKEN'; token: string }

function currentCsrfToken(signal?: AbortSignal): Promise<string> {
  if (csrfToken !== undefined) return Promise.resolve(csrfToken)
  if (csrfRequest === undefined) {
    const requestGeneration = authenticationGeneration
    csrfRequest = (async () => {
      const response = await fetch(`${apiBaseUrl}/api/auth/csrf`, {
        method: 'GET',
        headers: { Accept: 'application/json' },
        credentials: 'same-origin',
        cache: 'no-store',
        signal,
      })
      if (!response.ok) {
        if (response.status === 401 || response.status === 403) invalidateAuthentication()
        throw new ApiError(response.status)
      }
      const value = await response.json() as CsrfResponse
      if (value.headerName !== 'X-CSRF-TOKEN' || typeof value.token !== 'string' || value.token.length === 0) {
        throw new ApiError(503)
      }
      if (authenticationInvalidated || requestGeneration !== authenticationGeneration) throw new ApiError(401)
      csrfToken = value.token
      return value.token
    })().finally(() => { csrfRequest = undefined })
  }
  return csrfRequest
}

export interface ProblemDetails {
  type?: string
  title?: string
  status?: number
  detail?: string
}

export class ApiError extends Error {
  constructor(public readonly status: number, public readonly problem?: ProblemDetails) {
    super(`Geordi API request failed (${status})`)
    this.name = 'ApiError'
  }
}

async function requestJson<T>(path: string, method: 'GET' | 'POST', signal?: AbortSignal, body?: unknown): Promise<T> {
  if (authenticationInvalidated && path !== '/api/me') throw new ApiError(401)
  const requestGeneration = authenticationGeneration
  const token = method === 'POST' ? await currentCsrfToken(signal) : undefined
  if (authenticationInvalidated && path !== '/api/me' || requestGeneration !== authenticationGeneration) {
    throw new ApiError(401)
  }
  const response = await fetch(`${apiBaseUrl}${path}`, {
    method,
    credentials: 'same-origin',
    headers: {
      Accept: 'application/json',
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...(token === undefined ? {} : { 'X-CSRF-TOKEN': token }),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal,
  })

  if (requestGeneration !== authenticationGeneration) throw new ApiError(401)

  if (!response.ok) {
    if (response.status === 401 && path !== '/api/me' || response.status === 403 && method === 'POST') {
      invalidateAuthentication()
    }
    const contentType = response.headers.get('Content-Type') ?? ''
    let problem: ProblemDetails | undefined
    if (contentType.includes('application/problem+json')) {
      try {
        problem = (await response.json()) as ProblemDetails
      } catch {
        problem = undefined
      }
    }
    throw new ApiError(response.status, problem)
  }
  if (response.status === 204) return undefined as T
  return (await response.json()) as T
}

export function clearCsrfToken(): void {
  csrfToken = undefined
}

export function markAuthenticationValidated(principalChanged = false): void {
  if (principalChanged) authenticationGeneration += 1
  authenticationInvalidated = false
}

export function advanceAuthenticationGeneration(): void {
  authenticationGeneration += 1
  csrfToken = undefined
}

export function currentAuthenticationGeneration(): number {
  return authenticationGeneration
}

export function isAuthenticationGenerationCurrent(generation: number): boolean {
  return generation === authenticationGeneration && !authenticationInvalidated
}

export function invalidateAuthentication(): void {
  authenticationGeneration += 1
  authenticationInvalidated = true
  csrfToken = undefined
  if (typeof window !== 'undefined') window.dispatchEvent(new Event('geordi:auth-invalidated'))
}

export function getJson<T>(path: string, signal?: AbortSignal): Promise<T> {
  return requestJson(path, 'GET', signal)
}

export function postJson<T>(path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
  return requestJson(path, 'POST', signal, body)
}
