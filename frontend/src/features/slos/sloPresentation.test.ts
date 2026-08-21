import { describe, expect, it } from 'vitest'
import {
  burnRateUnavailableReason,
  formatBurnRate,
  formatRequestCount,
  formatRatio,
  sliLabel,
  targetComparison,
} from './sloPresentation'

describe('SLO presentation', () => {
  it('converts canonical ratios to percentages without confusing ratio and percent units', () => {
    expect(formatRatio(0)).toBe('0%')
    expect(formatRatio(0.001)).toBe('0.1%')
    expect(formatRatio(0.004)).toBe('0.4%')
    expect(formatRatio(0.999)).toBe('99.9%')
    expect(formatRatio(0.0000001)).toBe('0.00001%')
  })

  it('does not round valid boundary ratios to a misleading zero or one hundred percent', () => {
    expect(formatRatio(0.9999999)).toBe('99.99999%')
    expect(formatRatio(Number.MIN_VALUE)).not.toBe('0%')
    expect(formatRatio(Number.MIN_VALUE)).toMatch(/e-\d+%$/)
  })

  it('rejects non-finite and out-of-range numeric payloads at the presentation boundary', () => {
    expect(formatRatio(Number.NaN)).toBe('Unavailable')
    expect(formatRatio(Number.POSITIVE_INFINITY)).toBe('Unavailable')
    expect(formatRatio(-0.1)).toBe('Unavailable')
    expect(formatRatio(1.1)).toBe('Unavailable')
    expect(formatBurnRate(Number.NaN)).toBe('Unavailable')
    expect(formatBurnRate(Number.POSITIVE_INFINITY)).toBe('Unavailable')
    expect(formatRequestCount(Number.POSITIVE_INFINITY)).toBe('Unavailable')
    expect(formatRequestCount(-1)).toBe('Unavailable')
  })

  it('formats burn rate as a dimensionless multiplier', () => {
    expect(formatBurnRate(0)).toBe('0×')
    expect(formatBurnRate(0.25)).toBe('0.25×')
    expect(formatBurnRate(1)).toBe('1×')
    expect(formatBurnRate(4)).toBe('4×')
  })

  it('makes the SLI target direction explicit', () => {
    expect(sliLabel('AVAILABILITY')).toBe('Availability')
    expect(targetComparison('AVAILABILITY')).toBe('≥')
    expect(sliLabel('ERROR_RATE')).toBe('Error rate')
    expect(targetComparison('ERROR_RATE')).toBe('≤')
  })

  it('explains a zero allowed bad ratio without leaking infinity', () => {
    expect(burnRateUnavailableReason('ZERO_ALLOWED_BAD_RATIO')).toBe(
      'Burn rate is unavailable because this objective allows no bad events.',
    )
  })
})
