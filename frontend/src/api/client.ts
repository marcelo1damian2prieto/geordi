const configuredBaseUrl: unknown = import.meta.env.VITE_API_BASE_URL
const apiBaseUrl = typeof configuredBaseUrl === 'string'
  ? configuredBaseUrl.replace(/\/$/, '')
  : ''

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

async function requestJson<T>(path: string, method: 'GET' | 'POST', signal?: AbortSignal): Promise<T> {
  const response = await fetch(`${apiBaseUrl}${path}`, {
    method,
    headers: { Accept: 'application/json' },
    signal,
  })

  if (!response.ok) {
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
  return (await response.json()) as T
}

export function getJson<T>(path: string, signal?: AbortSignal): Promise<T> {
  return requestJson(path, 'GET', signal)
}

export function postJson<T>(path: string, signal?: AbortSignal): Promise<T> {
  return requestJson(path, 'POST', signal)
}
