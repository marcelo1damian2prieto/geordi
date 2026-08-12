export type ModuleStatus = 'UP' | 'DOWN' | 'UNKNOWN' | 'DISABLED'

export interface PlatformResponse {
  id: string
  name: string
  version: string
}

export interface ModuleResponse {
  id: string
  name: string
  enabled: boolean
  status: ModuleStatus
}

export interface ModulesResponse {
  modules: ModuleResponse[]
}

export interface PlatformHealthResponse {
  status: ModuleStatus
  modules: ModuleResponse[]
}
