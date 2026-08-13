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

export async function getJson<T>(path: string): Promise<T> {
  const response = await fetch(`${apiBaseUrl}${path}`, {
    headers: { Accept: 'application/json' },
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
