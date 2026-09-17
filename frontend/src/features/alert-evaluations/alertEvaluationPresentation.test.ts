import { describe, expect, it } from 'vitest'
import {
  alertBandLabel,
  alertBandOutcomeLabel,
  alertConditionLabel,
  alertConditionSummary,
  alertStatusLabel,
  alertUnavailableReason,
  alertWindowLabel,
  deriveMultiwindowBandResults,
  exactInvestigationTarget,
  formatAlertBurnRate,
  observationBurnRateLabel,
} from './alertEvaluationPresentation'

describe('alert evaluation presentation', () => {
  it('formats finite non-negative burn rates without changing canonical units', () => {
    expect(formatAlertBurnRate(0)).toBe('0×')
    expect(formatAlertBurnRate(2)).toBe('2×')
    expect(formatAlertBurnRate(3.75)).toBe('3.75×')
    expect(formatAlertBurnRate(1.0000004)).toBe('1.0000004×')
    expect(formatAlertBurnRate(1.0000005)).toBe('1.0000005×')
  })

  it('does not display invalid numeric payloads', () => {
    expect(formatAlertBurnRate(Number.NaN)).toBe('Unavailable')
    expect(formatAlertBurnRate(Number.POSITIVE_INFINITY)).toBe('Unavailable')
    expect(formatAlertBurnRate(-1)).toBe('Unavailable')
  })

  it('makes the inclusive condition and stateless results explicit', () => {
    expect(alertConditionLabel('BURN_RATE_ABOVE')).toBe('Burn rate ≥')
    expect(alertConditionLabel('MULTIWINDOW_BURN_RATE')).toBe('Multiwindow burn rate')
    expect(alertConditionSummary({
      type: 'MULTIWINDOW_BURN_RATE',
      bands: [{ longWindow: 'PT6H', shortWindow: 'PT30M', threshold: 6 }],
    })).toBe('Multiwindow burn rate · 1 band')
    expect(alertBandLabel({ longWindow: 'PT6H', shortWindow: 'PT30M', threshold: 6 })).toBe('6 hours + 30 minutes')
    expect(alertWindowLabel('PT30M')).toBe('30 minutes')
    expect(alertBandOutcomeLabel('NOT_MET')).toBe('Not met')
    expect(alertStatusLabel('CONDITION_MET')).toBe('Condition met')
    expect(alertStatusLabel('CONDITION_NOT_MET')).toBe('Condition not met')
    expect(alertStatusLabel('UNAVAILABLE')).toBe('Unavailable')
  })

  it('explains unavailable canonical evidence', () => {
    expect(alertUnavailableReason('NO_TRAFFIC')).toBe('No traffic was observed in this evaluation window.')
    expect(alertUnavailableReason('METRICS_UNAVAILABLE')).toBe('Metrics storage is unavailable for this evaluation.')
    expect(alertUnavailableReason('ZERO_ALLOWED_BAD_RATIO')).toContain('allows no bad events')
    expect(alertUnavailableReason('MULTIWINDOW_EVIDENCE_UNAVAILABLE')).toContain('no band met')
    expect(observationBurnRateLabel({
      observationWindow: 'PT30M',
      range: { from: '2026-01-01T00:00:00Z', to: '2026-01-01T00:30:00Z' },
      observedBurnRate: null,
      reason: 'NO_TRAFFIC',
    })).toContain('No traffic')
  })

  it('derives canonical three-valued band results only from matching multiwindow evidence', () => {
    const condition = {
      type: 'MULTIWINDOW_BURN_RATE' as const,
      bands: [{ longWindow: 'PT1H' as const, shortWindow: 'PT5M' as const, threshold: 14.4 }],
    }
    const longObservation = {
      observationWindow: 'PT1H' as const,
      range: { from: '2026-01-01T00:00:00Z', to: '2026-01-01T01:00:00Z' },
      observedBurnRate: 10,
      reason: null,
    }
    const shortObservation = {
      observationWindow: 'PT5M' as const,
      range: { from: '2026-01-01T00:55:00Z', to: '2026-01-01T01:00:00Z' },
      observedBurnRate: null,
      reason: 'NO_TRAFFIC' as const,
    }
    const evidence = {
      service: { name: 'checkout', namespace: null, environment: 'production' },
      configuredSloWindow: 'PT15M' as const,
      evaluatedAt: '2026-01-01T01:00:00Z',
      observations: [shortObservation, longObservation],
    }

    expect(deriveMultiwindowBandResults(condition, evidence)).toEqual([{
      band: condition.bands[0],
      longObservation,
      shortObservation,
      outcome: 'NOT_MET',
    }])
    expect(deriveMultiwindowBandResults(condition, {
      ...evidence,
      observations: [longObservation, longObservation],
    })).toBeUndefined()
  })

  it('only builds Investigation links that preserve an exact valid range and identity', () => {
    const service = { name: 'checkout', namespace: null, environment: 'production' }
    const range = { from: '2026-01-01T00:00:00.123456789Z', to: '2026-01-01T06:00:00.123456789Z' }
    const target = new URL(exactInvestigationTarget(service, range)!, 'http://geordi.test')
    expect(target.searchParams.get('from')).toBe(range.from)
    expect(target.searchParams.get('to')).toBe(range.to)
    expect(exactInvestigationTarget(service, { ...range, from: '2025-12-31T23:59:59Z' })).toBeNull()
    expect(exactInvestigationTarget({ ...service, name: ' checkout' }, range)).toBeNull()
  })
})
