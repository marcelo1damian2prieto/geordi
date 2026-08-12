import type {
  ModulesResponse,
  PlatformHealthResponse,
  PlatformResponse,
} from './types'

const configuredBaseUrl: unknown = import.meta.env.VITE_API_BASE_URL
const apiBaseUrl = typeof configuredBaseUrl === 'string'
  ? configuredBaseUrl.replace(/\/$/, '')
  : ''

async function getJson<T>(path: string): Promise<T> {
  const response = await fetch(`${apiBaseUrl}${path}`, {
    headers: { Accept: 'application/json' },
  })

  if (!response.ok) {
    throw new Error(`Geordi API request failed (${response.status})`)
  }

  return (await response.json()) as T
}

export async function getPlatformOverview() {
  const [platform, modules, health] = await Promise.all([
    getJson<PlatformResponse>('/api/platform'),
    getJson<ModulesResponse>('/api/modules'),
    getJson<PlatformHealthResponse>('/api/platform/health'),
  ])

  return { platform, modules: modules.modules, health }
}
