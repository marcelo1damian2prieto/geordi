const configuredBaseUrl: unknown = import.meta.env.VITE_API_BASE_URL
const apiBaseUrl = typeof configuredBaseUrl === 'string'
  ? configuredBaseUrl.replace(/\/$/, '')
  : ''

export class ApiError extends Error {
  constructor(public readonly status: number) {
    super(`Geordi API request failed (${status})`)
    this.name = 'ApiError'
  }
}

export async function getJson<T>(path: string): Promise<T> {
  const response = await fetch(`${apiBaseUrl}${path}`, {
    headers: { Accept: 'application/json' },
  })

  if (!response.ok) throw new ApiError(response.status)
  return (await response.json()) as T
}
