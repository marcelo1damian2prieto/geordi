import { getJson } from './client'
import type { SloWindow } from './slos'
import type { ServiceIdentity, TimeRange } from './telemetryContext'

export type AlertConditionType = 'BURN_RATE_ABOVE' | 'MULTIWINDOW_BURN_RATE'
export type AlertEvaluationStatus = 'CONDITION_MET' | 'CONDITION_NOT_MET' | 'UNAVAILABLE'
export type AlertObservationWindow = 'PT5M' | 'PT30M' | 'PT1H' | 'PT6H'
export type ObservationUnavailableReason =
  | 'DISABLED'
  | 'NO_TRAFFIC'
  | 'MISSING_REQUEST_COUNT'
  | 'MISSING_ERROR_COUNT'
  | 'INVALID_TELEMETRY'
  | 'METRICS_UNAVAILABLE'
  | 'ZERO_ALLOWED_BAD_RATIO'
export type AlertUnavailableReason = ObservationUnavailableReason
export type MultiwindowAggregateUnavailableReason = 'DISABLED' | 'MULTIWINDOW_EVIDENCE_UNAVAILABLE'
export type BurnRateBandOutcome = 'MET' | 'NOT_MET' | 'UNAVAILABLE'

export interface LegacyAlertCondition {
  type: 'BURN_RATE_ABOVE'
  threshold: number
}

export type BurnRateBand =
  | { longWindow: 'PT1H'; shortWindow: 'PT5M'; threshold: number }
  | { longWindow: 'PT6H'; shortWindow: 'PT30M'; threshold: number }

export interface MultiwindowAlertCondition {
  type: 'MULTIWINDOW_BURN_RATE'
  bands: BurnRateBand[]
}

export type AlertCondition = LegacyAlertCondition | MultiwindowAlertCondition

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

export interface LegacyAlertEvidence {
  service: ServiceIdentity
  window: SloWindow
  range: TimeRange
  evaluatedAt: string
  observedBurnRate: number | null
}

export type WindowBurnRateObservation =
  | {
      observationWindow: AlertObservationWindow
      range: TimeRange
      observedBurnRate: number
      reason: null
    }
  | {
      observationWindow: AlertObservationWindow
      range: TimeRange
      observedBurnRate: null
      reason: ObservationUnavailableReason
    }

export interface MultiwindowAlertEvidence {
  service: ServiceIdentity
  configuredSloWindow: SloWindow
  evaluatedAt: string
  observations: WindowBurnRateObservation[]
}

export type AlertEvidence = LegacyAlertEvidence | MultiwindowAlertEvidence

export interface BurnRateBandResult {
  band: BurnRateBand
  longObservation: WindowBurnRateObservation
  shortObservation: WindowBurnRateObservation
  outcome: BurnRateBandOutcome
}

interface AlertEvaluationBase {
  policyId: string
  policyName: string
  sloId: string
  status: AlertEvaluationStatus
}

export interface LegacyAlertEvaluation extends AlertEvaluationBase {
  condition: LegacyAlertCondition
  reason: AlertUnavailableReason | null
  evidence: LegacyAlertEvidence | null
}

export interface MultiwindowAlertEvaluation extends AlertEvaluationBase {
  condition: MultiwindowAlertCondition
  reason: MultiwindowAggregateUnavailableReason | null
  evidence: MultiwindowAlertEvidence | null
  bandResults: BurnRateBandResult[]
}

export type AlertEvaluation = LegacyAlertEvaluation | MultiwindowAlertEvaluation

export function isMultiwindowAlertEvaluation(
  evaluation: AlertEvaluation,
): evaluation is MultiwindowAlertEvaluation {
  return evaluation.condition.type === 'MULTIWINDOW_BURN_RATE'
}

export function alertConditionKey(condition: AlertCondition) {
  return condition.type === 'BURN_RATE_ABOVE'
    ? [condition.type, condition.threshold] as const
    : [
        condition.type,
        ...[...condition.bands]
          .sort((left, right) => (left.longWindow === 'PT1H' ? 0 : 1) - (right.longWindow === 'PT1H' ? 0 : 1))
          .map((band) => [band.longWindow, band.shortWindow, band.threshold] as const),
      ] as const
}

export function getAlertPolicies() {
  return getJson<AlertPoliciesResponse>('/api/alert-policies')
}

export function getAlertEvaluation(policyId: string) {
  return getJson<AlertEvaluation>(`/api/alert-policies/${encodeURIComponent(policyId)}/evaluation`)
}
