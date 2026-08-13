import { describe, expect, it } from 'vitest'
import { chartOption, formatMetricValue } from './metricPresentation'

describe('metric presentation', () => {
  it('formats canonical units without confusing a ratio with a percentage value', () => {
    expect(formatMetricValue(0.125, '1')).toBe('13%')
    expect(formatMetricValue(0, '{request}/s')).toBe('0.00 req/s')
    expect(formatMetricValue(0.25, 's')).toBe('250 ms')
  })

  it('orders timestamped values and enables chart accessibility', () => {
    const option = chartOption({
      metric: 'JVM_THREAD_COUNT',
      unit: '{thread}',
      points: [
        { timestamp: '2026-08-13T15:01:00Z', value: 7 },
        { timestamp: '2026-08-13T15:00:00Z', value: 6 },
      ],
    })

    expect(option.aria).toMatchObject({ enabled: true })
    expect(option.series).toEqual(expect.arrayContaining([
      expect.objectContaining({ data: [['2026-08-13T15:00:00Z', 6], ['2026-08-13T15:01:00Z', 7]] }),
    ]))
  })
})
