import { describe, expect, it } from 'vitest'
import {
  alertConditionLabel,
  alertStatusLabel,
  alertUnavailableReason,
  formatAlertBurnRate,
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
    expect(alertStatusLabel('CONDITION_MET')).toBe('Condition met')
    expect(alertStatusLabel('CONDITION_NOT_MET')).toBe('Condition not met')
    expect(alertStatusLabel('UNAVAILABLE')).toBe('Unavailable')
  })

  it('explains unavailable canonical evidence', () => {
    expect(alertUnavailableReason('NO_TRAFFIC')).toBe('No traffic was observed in this evaluation window.')
    expect(alertUnavailableReason('METRICS_UNAVAILABLE')).toBe('Metrics storage is unavailable for this evaluation.')
    expect(alertUnavailableReason('ZERO_ALLOWED_BAD_RATIO')).toContain('allows no bad events')
  })
})
