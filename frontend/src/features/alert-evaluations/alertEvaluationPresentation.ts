import type {
  AlertConditionType,
  AlertEvaluationStatus,
  AlertUnavailableReason,
} from '../../api/alertEvaluations'
import type { SloWindow } from '../../api/slos'

export function formatAlertBurnRate(value: number) {
  if (!Number.isFinite(value) || value < 0) return 'Unavailable'
  return `${value.toString()}×`
}

export function alertConditionLabel(type: AlertConditionType) {
  return type === 'BURN_RATE_ABOVE' ? 'Burn rate ≥' : 'Unsupported condition'
}

export function alertStatusLabel(status: AlertEvaluationStatus) {
  return ({
    CONDITION_MET: 'Condition met',
    CONDITION_NOT_MET: 'Condition not met',
    UNAVAILABLE: 'Unavailable',
  })[status]
}

export function alertUnavailableReason(reason: AlertUnavailableReason | null) {
  if (reason === null) return 'This condition could not be evaluated.'
  return ({
    DISABLED: 'This policy is disabled.',
    NO_TRAFFIC: 'No traffic was observed in this evaluation window.',
    MISSING_REQUEST_COUNT: 'Request count telemetry is unavailable for this evaluation window.',
    MISSING_ERROR_COUNT: 'Error count telemetry is unavailable for this evaluation window.',
    INVALID_TELEMETRY: 'Telemetry values are invalid for this evaluation.',
    METRICS_UNAVAILABLE: 'Metrics storage is unavailable for this evaluation.',
    ZERO_ALLOWED_BAD_RATIO: 'Burn rate is unavailable because the referenced objective allows no bad events.',
  })[reason]
}

export function alertWindowLabel(window: SloWindow) {
  return ({ PT5M: '5 minutes', PT15M: '15 minutes', PT1H: '1 hour', PT6H: '6 hours' })[window]
}
