import { describe, expect, it } from 'vitest'
import type { TraceSummary } from '../../api/traces'
import { latestPoint, recentTraces, slowestRecentTraces } from './investigationPresentation'

const traces: TraceSummary[] = [
  { traceId: 'a'.repeat(32), rootSpanName: 'recent fast', startTime: '2026-08-13T14:59:00Z', durationNanos: 10, spanCount: 1, error: false },
  { traceId: 'b'.repeat(32), rootSpanName: 'older slow', startTime: '2026-08-13T14:58:00Z', durationNanos: 30, spanCount: 1, error: false },
  { traceId: 'c'.repeat(32), rootSpanName: 'older medium', startTime: '2026-08-13T14:57:00Z', durationNanos: 20, spanCount: 1, error: true },
]

describe('investigation presentation', () => {
  it('preserves API order for recent traces and sorts a copy for slowest recent traces', () => {
    expect(recentTraces(traces).map((trace) => trace.rootSpanName)).toEqual(['recent fast', 'older slow', 'older medium'])
    expect(slowestRecentTraces(traces).map((trace) => trace.rootSpanName)).toEqual(['older slow', 'older medium', 'recent fast'])
    expect(traces.map((trace) => trace.rootSpanName)).toEqual(['recent fast', 'older slow', 'older medium'])
  })

  it('bounds both trace presentations to five with deterministic duration ties', () => {
    const many = Array.from({ length: 7 }, (_, index) => ({
      ...traces[0], traceId: index.toString(16).padStart(32, '0'), durationNanos: 100,
    }))
    expect(recentTraces(many)).toHaveLength(5)
    expect(slowestRecentTraces(many).map((trace) => trace.traceId)).toEqual(
      many.map((trace) => trace.traceId).sort().slice(0, 5),
    )
  })

  it('returns the chronologically latest point and preserves a valid zero', () => {
    expect(latestPoint([
      { timestamp: '2026-08-13T15:00:00Z', value: 0 },
      { timestamp: '2026-08-13T14:59:00Z', value: 9 },
    ])).toEqual({ timestamp: '2026-08-13T15:00:00Z', value: 0 })
    expect(latestPoint([])).toBeUndefined()
  })
})
