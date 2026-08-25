import { getJson } from './client'
import type { SloWindow } from './slos'
import type { ServiceIdentity, TimeRange } from './telemetryContext'

export type AlertConditionType = 'BURN_RATE_ABOVE'
export type AlertEvaluationStatus = 'CONDITION_MET' | 'CONDITION_NOT_MET' | 'UNAVAILABLE'
export type AlertUnavailableReason =
  | 'DISABLED'
  | 'NO_TRAFFIC'
  | 'MISSING_REQUEST_COUNT'
  | 'MISSING_ERROR_COUNT'
  | 'INVALID_TELEMETRY'
  | 'METRICS_UNAVAILABLE'
  | 'ZERO_ALLOWED_BAD_RATIO'

export interface AlertCondition {
  type: AlertConditionType
  threshold: number
}

export interface AlertPolicy {
  id: string
  name: string
  description: string | null
  enabled: boolean
  sloId: string
  condition: AlertCondition
}

export interface AlertPoliciesResponse {
  alertPolicies: AlertPolicy[]
}

export interface AlertEvidence {
  service: ServiceIdentity
  window: SloWindow
  range: TimeRange
  evaluatedAt: string
  observedBurnRate: number | null
}

export interface AlertEvaluation {
  policyId: string
  policyName: string
  sloId: string
  condition: AlertCondition
  status: AlertEvaluationStatus
  reason: AlertUnavailableReason | null
  evidence: AlertEvidence | null
}

export function getAlertPolicies() {
  return getJson<AlertPoliciesResponse>('/api/alert-policies')
}

export function getAlertEvaluation(policyId: string) {
  return getJson<AlertEvaluation>(`/api/alert-policies/${encodeURIComponent(policyId)}/evaluation`)
}
