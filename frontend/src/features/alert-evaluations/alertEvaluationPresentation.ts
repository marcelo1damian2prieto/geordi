import type {
  AlertCondition,
  AlertConditionType,
  AlertEvidence,
  AlertEvaluationStatus,
  BurnRateBand,
  BurnRateBandResult,
  BurnRateBandOutcome,
  LegacyAlertEvidence,
  MultiwindowAlertCondition,
  MultiwindowAlertEvidence,
  MultiwindowAggregateUnavailableReason,
  ObservationUnavailableReason,
  WindowBurnRateObservation,
} from '../../api/alertEvaluations'
import type { SloWindow } from '../../api/slos'
import type { ServiceIdentity, TimeRange } from '../../api/telemetryContext'
import { contextSearchParams, parseTelemetryContext } from '../../api/telemetryContext'

export function formatAlertBurnRate(value: number) {
  if (!Number.isFinite(value) || value < 0) return 'Unavailable'
  return `${value.toString()}×`
}

export function alertConditionLabel(type: AlertConditionType) {
  return type === 'BURN_RATE_ABOVE' ? 'Burn rate ≥' : 'Multiwindow burn rate'
}

export function alertConditionSummary(condition: AlertCondition) {
  return condition.type === 'BURN_RATE_ABOVE'
    ? `${alertConditionLabel(condition.type)} ${formatAlertBurnRate(condition.threshold)}`
    : `${alertConditionLabel(condition.type)} · ${condition.bands.length} ${condition.bands.length === 1 ? 'band' : 'bands'}`
}

export function alertStatusLabel(status: AlertEvaluationStatus) {
  return ({
    CONDITION_MET: 'Condition met',
    CONDITION_NOT_MET: 'Condition not met',
    UNAVAILABLE: 'Unavailable',
  })[status]
}

export function alertUnavailableReason(
  reason: ObservationUnavailableReason | MultiwindowAggregateUnavailableReason | null,
) {
  if (reason === null) return 'This condition could not be evaluated.'
  return ({
    DISABLED: 'This policy or its referenced SLO is disabled.',
    NO_TRAFFIC: 'No traffic was observed in this evaluation window.',
    MISSING_REQUEST_COUNT: 'Request count telemetry is unavailable for this evaluation window.',
    MISSING_ERROR_COUNT: 'Error count telemetry is unavailable for this evaluation window.',
    INVALID_TELEMETRY: 'Telemetry values are invalid for this evaluation.',
    METRICS_UNAVAILABLE: 'Metrics storage is unavailable for this evaluation.',
    ZERO_ALLOWED_BAD_RATIO: 'Burn rate is unavailable because the referenced objective allows no bad events.',
    MULTIWINDOW_EVIDENCE_UNAVAILABLE: 'At least one burn-rate band remains unavailable and no band met its threshold.',
  })[reason]
}

export function alertWindowLabel(window: SloWindow | WindowBurnRateObservation['observationWindow']) {
  return ({ PT5M: '5 minutes', PT15M: '15 minutes', PT30M: '30 minutes', PT1H: '1 hour', PT6H: '6 hours' })[window]
}

export function alertBandLabel(band: BurnRateBand) {
  return `${alertWindowLabel(band.longWindow)} + ${alertWindowLabel(band.shortWindow)}`
}

export function alertBandOutcomeLabel(outcome: BurnRateBandOutcome) {
  return ({ MET: 'Met', NOT_MET: 'Not met', UNAVAILABLE: 'Unavailable' })[outcome]
}

export function observationBurnRateLabel(observation: WindowBurnRateObservation) {
  return observation.observedBurnRate === null
    ? `Unavailable — ${alertUnavailableReason(observation.reason)}`
    : formatAlertBurnRate(observation.observedBurnRate)
}

export function isLegacyAlertEvidence(evidence: AlertEvidence): evidence is LegacyAlertEvidence {
  return 'window' in evidence
}

export function isMultiwindowAlertEvidence(evidence: AlertEvidence): evidence is MultiwindowAlertEvidence {
  return 'observations' in evidence
}

export function deriveMultiwindowBandResults(
  condition: MultiwindowAlertCondition,
  evidence: MultiwindowAlertEvidence,
): BurnRateBandResult[] | undefined {
  const observations = new Map<WindowBurnRateObservation['observationWindow'], WindowBurnRateObservation>()
  for (const observation of evidence.observations) {
    if (observations.has(observation.observationWindow)) return undefined
    observations.set(observation.observationWindow, observation)
  }

  const expectedWindows = new Set(condition.bands.flatMap((band) => [band.longWindow, band.shortWindow]))
  if (observations.size !== expectedWindows.size
    || [...expectedWindows].some((window) => !observations.has(window))) return undefined

  return condition.bands.map((band) => {
    const longObservation = observations.get(band.longWindow)!
    const shortObservation = observations.get(band.shortWindow)!
    const belowThreshold = [longObservation, shortObservation]
      .some((observation) => observation.observedBurnRate !== null
        && observation.observedBurnRate < band.threshold)
    const outcome = belowThreshold
      ? 'NOT_MET'
      : longObservation.observedBurnRate !== null && shortObservation.observedBurnRate !== null
        ? 'MET'
        : 'UNAVAILABLE'
    return { band, longObservation, shortObservation, outcome }
  })
}

export function exactInvestigationTarget(service: ServiceIdentity, range: TimeRange) {
  const params = contextSearchParams(service, range)
  const parsed = parseTelemetryContext(params)
  if (parsed.status !== 'valid') return null
  const parsedContext = parsed.context
  if (parsedContext.service.name !== service.name
    || parsedContext.service.namespace !== service.namespace
    || parsedContext.service.environment !== service.environment
    || parsedContext.range.from !== range.from
    || parsedContext.range.to !== range.to) return null
  return `/investigate?${params.toString()}`
}
