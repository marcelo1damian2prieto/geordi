import type {
  ModulesResponse,
  PlatformHealthResponse,
  PlatformResponse,
} from './types'
import { getJson } from './client'

export async function getPlatformOverview() {
  const [platform, modules, health] = await Promise.all([
    getJson<PlatformResponse>('/api/platform'),
    getJson<ModulesResponse>('/api/modules'),
    getJson<PlatformHealthResponse>('/api/platform/health'),
  ])

  return { platform, modules: modules.modules, health }
}
