import type {
  BurnRateUnavailableReason,
  SliType,
  SloUnavailableReason,
  SloWindow,
} from '../../api/slos'

const percentageFormatter = new Intl.NumberFormat('en-US', {
  style: 'percent',
  maximumSignificantDigits: 12,
})

const burnRateFormatter = new Intl.NumberFormat('en-US', {
  maximumSignificantDigits: 6,
})

export function formatRatio(value: number) {
  if (!Number.isFinite(value) || value < 0 || value > 1) return 'Unavailable'
  if (value === 0) return '0%'
  if (value === 1) return '100%'

  const formatted = percentageFormatter.format(value)
  if (formatted === '0%') return `${(value * 100).toExponential(6)}%`
  if (formatted === '100%') return '< 100%'
  if (formatted.length > 30) return `${(value * 100).toExponential(6)}%`
  return formatted
}

export function formatBurnRate(value: number) {
  if (!Number.isFinite(value) || value < 0) return 'Unavailable'
  return `${burnRateFormatter.format(value)}×`
}

export function formatRequestCount(value: number) {
  if (!Number.isFinite(value) || value < 0) return 'Unavailable'
  return value.toLocaleString('en-US', { maximumFractionDigits: 6 })
}

export function sliLabel(sliType: SliType) {
  return sliType === 'AVAILABILITY' ? 'Availability' : 'Error rate'
}

export function targetComparison(sliType: SliType) {
  return sliType === 'AVAILABILITY' ? '≥' : '≤'
}

export function windowLabel(window: SloWindow) {
  return ({ PT5M: '5 minutes', PT15M: '15 minutes', PT1H: '1 hour', PT6H: '6 hours' })[window]
}

export function sloUnavailableReason(reason: SloUnavailableReason | null) {
  if (reason === null) return 'This objective could not be evaluated.'
  return ({
    DISABLED: 'This objective is disabled.',
    NO_TRAFFIC: 'No traffic in this evaluation window.',
    MISSING_REQUEST_COUNT: 'Request count telemetry is unavailable for this evaluation window.',
    MISSING_ERROR_COUNT: 'Error count telemetry is unavailable for this evaluation window.',
    INVALID_TELEMETRY: 'Telemetry values are invalid for this evaluation.',
    METRICS_UNAVAILABLE: 'Metrics storage is unavailable for this evaluation.',
  })[reason]
}

export function burnRateUnavailableReason(reason: BurnRateUnavailableReason | null) {
  if (reason === null) return 'Burn-rate evidence is unavailable.'
  return ({
    DISABLED: 'Burn rate is unavailable because this objective is disabled.',
    NO_TRAFFIC: 'Burn rate is unavailable because there was no traffic in this evaluation window.',
    MISSING_REQUEST_COUNT: 'Burn rate is unavailable because request count telemetry is missing.',
    MISSING_ERROR_COUNT: 'Burn rate is unavailable because error count telemetry is missing.',
    INVALID_TELEMETRY: 'Burn rate is unavailable because telemetry values are invalid.',
    METRICS_UNAVAILABLE: 'Burn rate is unavailable because Metrics storage could not be queried.',
    ZERO_ALLOWED_BAD_RATIO: 'Burn rate is unavailable because this objective allows no bad events.',
  })[reason]
}
