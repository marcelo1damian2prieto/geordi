import { describe, expect, it } from 'vitest'
import type { TraceSpan } from '../../api/traces'
import { formatDuration, presentSpans } from './tracePresentation'

function span(spanId: string, parentSpanId: string | null, startOffsetNanos: number, durationNanos: number): TraceSpan {
  return {
    traceId: 'a'.repeat(32), spanId, parentSpanId, name: spanId,
    service: { name: 'checkout', namespace: 'store', environment: 'local' },
    telemetryOrigin: 'monitored', kind: 'INTERNAL', status: 'UNSET',
    startTime: '2026-08-13T15:00:00Z', startOffsetNanos, durationNanos,
    error: false, errorType: null, http: null,
  }
}

describe('trace presentation', () => {
  it('derives hierarchy depth and timing percentages without reordering spans', () => {
    const spans = [span('root', null, 0, 100), span('child', 'root', 20, 50), span('leaf', 'child', 30, 10)]

    expect(presentSpans(spans, 100).map(({ span: item, depth, leftPercent, widthPercent }) => ({
      id: item.spanId, depth, leftPercent, widthPercent,
    }))).toEqual([
      { id: 'root', depth: 0, leftPercent: 0, widthPercent: 100 },
      { id: 'child', depth: 1, leftPercent: 20, widthPercent: 50 },
      { id: 'leaf', depth: 2, leftPercent: 30, widthPercent: 10 },
    ])
  })

  it('formats trace-scale nanosecond durations', () => {
    expect(formatDuration(500)).toBe('500 ns')
    expect(formatDuration(50_000_000)).toBe('50.0 ms')
    expect(formatDuration(2_500_000_000)).toBe('2.50 s')
  })
})
