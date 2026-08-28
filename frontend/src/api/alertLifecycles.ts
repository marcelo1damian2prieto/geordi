import { getJson, postJson } from './client'
import type { AlertEvaluation, AlertEvidence, AlertPolicy } from './alertEvaluations'

export type AlertLifecycleState = 'INACTIVE' | 'FIRING'
export type AlertTransitionType = 'ALERT_STARTED' | 'ALERT_RESOLVED'
export type AlertLifecycleProcessingOutcome = 'APPLIED' | 'STALE_IGNORED' | 'DUPLICATE_IGNORED'

export interface AlertTransition {
  policyId: string
  type: AlertTransitionType
  previousState: AlertLifecycleState
  currentState: AlertLifecycleState
  occurredAt: string
  evaluation: AlertEvaluation
}

export interface AlertLifecycleSnapshot {
  policy: AlertPolicy
  initialized: boolean
  state: AlertLifecycleState
  latestEvaluation: AlertEvaluation | null
  activeEvidence: AlertEvidence | null
  startedAt: string | null
  resolvedAt: string | null
  lastStateChangeAt: string | null
  lastProcessedAt: string | null
  lastEvidenceAt: string | null
  latestTransition: AlertTransition | null
}

export interface AlertStatesResponse {
  alertStates: AlertLifecycleSnapshot[]
}

export interface AlertLifecycleEvaluationResult {
  triggeringEvaluation: AlertEvaluation
  outcome: AlertLifecycleProcessingOutcome
  current: AlertLifecycleSnapshot
  transition: AlertTransition | null
}

export function getAlertStates(signal?: AbortSignal) {
  return getJson<AlertStatesResponse>('/api/alert-states', signal)
}

export function evaluateAlertLifecycle(policyId: string) {
  return postJson<AlertLifecycleEvaluationResult>(
    `/api/alert-policies/${encodeURIComponent(policyId)}/lifecycle-evaluations`,
  )
}
