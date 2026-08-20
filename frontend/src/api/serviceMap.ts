import { getJson } from './client'
import { rangeParams, type ServiceIdentity, type TimeRange } from './telemetryContext'

export interface ServiceMapContext {
  environment: string
  range: TimeRange
}

export interface DependencyEvidence {
  traceId: string
  observedAt: string
}

export interface ObservedDependency {
  caller: ServiceIdentity
  callee: ServiceIdentity
  evidenceCount: number
  evidence: DependencyEvidence[]
}

export interface ServiceMapResponse {
  context: ServiceMapContext
  nodes: ServiceIdentity[]
  edges: ObservedDependency[]
  truncated: boolean
}

export function getServiceMap(environment: string, range: TimeRange) {
  const params = rangeParams(range)
  params.set('environment', environment)
  return getJson<ServiceMapResponse>(`/api/service-map?${params.toString()}`)
}
