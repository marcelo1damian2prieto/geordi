import type { TraceSpan } from '../../api/traces'

export interface PresentedSpan {
  span: TraceSpan
  depth: number
  leftPercent: number
  widthPercent: number
}

function spanDepth(span: TraceSpan, byId: ReadonlyMap<string, TraceSpan>) {
  let depth = 0
  let parentId = span.parentSpanId
  const visited = new Set<string>([span.spanId])
  while (parentId !== null && !visited.has(parentId)) {
    const parent = byId.get(parentId)
    if (!parent) break
    visited.add(parentId)
    depth += 1
    parentId = parent.parentSpanId
  }
  return depth
}

export function presentSpans(spans: readonly TraceSpan[], traceDurationNanos: number): PresentedSpan[] {
  const byId = new Map(spans.map((span) => [span.spanId, span]))
  return spans.map((span) => ({
    span,
    depth: spanDepth(span, byId),
    leftPercent: traceDurationNanos > 0 ? Math.max(0, Math.min(100, span.startOffsetNanos / traceDurationNanos * 100)) : 0,
    widthPercent: traceDurationNanos > 0 ? Math.max(0, Math.min(100, span.durationNanos / traceDurationNanos * 100)) : 0,
  }))
}

export function formatDuration(durationNanos: number) {
  if (durationNanos < 1_000) return `${durationNanos} ns`
  if (durationNanos < 1_000_000) return `${(durationNanos / 1_000).toFixed(1)} µs`
  if (durationNanos < 1_000_000_000) return `${(durationNanos / 1_000_000).toFixed(1)} ms`
  return `${(durationNanos / 1_000_000_000).toFixed(2)} s`
}
