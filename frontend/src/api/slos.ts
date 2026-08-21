import { getJson } from './client'
import type { ServiceIdentity, TimeRange } from './telemetryContext'

export type SliType = 'AVAILABILITY' | 'ERROR_RATE'
export type SloWindow = 'PT5M' | 'PT15M' | 'PT1H' | 'PT6H'
export type SloStatus = 'MET' | 'BREACHED' | 'UNAVAILABLE'
export type SloUnavailableReason =
  | 'DISABLED'
  | 'NO_TRAFFIC'
  | 'MISSING_REQUEST_COUNT'
  | 'MISSING_ERROR_COUNT'
  | 'INVALID_TELEMETRY'
  | 'METRICS_UNAVAILABLE'

export interface SloDefinition {
  id: string
  name: string
  description: string | null
  service: ServiceIdentity
  sliType: SliType
  target: number
  window: SloWindow
  enabled: boolean
}

export interface SloDefinitionsResponse {
  slos: SloDefinition[]
}

export interface SloEvaluation {
  sloId: string
  service: ServiceIdentity
  sliType: SliType
  target: number
  window: SloWindow
  range: TimeRange
  evaluatedAt: string
  observedValue: number | null
  requestCount: number | null
  status: SloStatus
  reason: SloUnavailableReason | null
}

export function getSlos() {
  return getJson<SloDefinitionsResponse>('/api/slos')
}

export function getSloEvaluation(sloId: string) {
  return getJson<SloEvaluation>(`/api/slos/${encodeURIComponent(sloId)}/evaluation`)
}
