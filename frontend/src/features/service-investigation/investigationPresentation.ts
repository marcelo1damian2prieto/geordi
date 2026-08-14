import type { MetricPoint } from '../../api/metrics'
import type { TraceSummary } from '../../api/traces'

const visibleTraceLimit = 5

export function latestPoint(points: readonly MetricPoint[]) {
  return points.reduce<MetricPoint | undefined>((latest, point) =>
    latest === undefined || point.timestamp > latest.timestamp ? point : latest, undefined)
}

export function recentTraces(traces: readonly TraceSummary[]) {
  return traces.slice(0, visibleTraceLimit)
}

export function slowestRecentTraces(traces: readonly TraceSummary[]) {
  return [...traces]
    .sort((left, right) => right.durationNanos - left.durationNanos || left.traceId.localeCompare(right.traceId))
    .slice(0, visibleTraceLimit)
}
