import type { EChartsCoreOption } from 'echarts/core'
import type { MetricSeries, MetricUnit, OperationalMetric } from '../../api/metrics'

export interface MetricConcept {
  id: string
  title: string
  primary: OperationalMetric
  secondary?: OperationalMetric
  secondaryLabel?: string
}

export const metricConcepts: readonly MetricConcept[] = [
  { id: 'requests', title: 'HTTP requests', primary: 'HTTP_REQUEST_RATE', secondary: 'HTTP_REQUEST_COUNT', secondaryLabel: 'requests in selected range' },
  { id: 'latency', title: 'HTTP p95 latency', primary: 'HTTP_REQUEST_LATENCY_P95' },
  { id: 'errors', title: 'HTTP errors', primary: 'HTTP_ERROR_RATE', secondary: 'HTTP_ERROR_COUNT', secondaryLabel: 'errors in selected range' },
  { id: 'memory', title: 'JVM memory used', primary: 'JVM_MEMORY_USED' },
  { id: 'cpu', title: 'JVM CPU utilization', primary: 'JVM_CPU_UTILIZATION' },
  { id: 'threads', title: 'JVM threads', primary: 'JVM_THREAD_COUNT' },
  { id: 'gc', title: 'JVM GC duration', primary: 'JVM_GC_DURATION' },
] as const

export const seriesMetricIds = metricConcepts.map(({ primary }) => primary)

export function formatMetricValue(value: number, unit: MetricUnit): string {
  if (!Number.isFinite(value)) return 'Unavailable'
  switch (unit) {
    case 'By': return formatBytes(value)
    case '1': return `${(value * 100).toFixed(value < 0.1 ? 1 : 0)}%`
    case 's': return value < 1 ? `${Math.round(value * 1000)} ms` : `${value.toFixed(2)} s`
    case '{thread}': return `${Math.round(value)}`
    case '{request}/s': return `${value.toFixed(2)} req/s`
    case '{request}': return Math.round(value).toLocaleString()
  }
}

function formatBytes(value: number) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB']
  let scaled = value
  let index = 0
  while (scaled >= 1024 && index < units.length - 1) {
    scaled /= 1024
    index += 1
  }
  return `${scaled.toFixed(index === 0 ? 0 : 1)} ${units[index]}`
}

export function chartOption(series: MetricSeries): EChartsCoreOption {
  return {
    animation: false,
    aria: { enabled: true, decal: { show: true } },
    color: ['#76a9e8'],
    grid: { left: 56, right: 18, top: 18, bottom: 36 },
    tooltip: { trigger: 'axis' },
    xAxis: { type: 'time', axisLabel: { color: '#91a0b5' }, axisLine: { lineStyle: { color: '#31445f' } } },
    yAxis: {
      type: 'value',
      min: 0,
      axisLabel: { color: '#91a0b5' },
      splitLine: { lineStyle: { color: '#26364e' } },
    },
    series: [{
      type: 'line',
      name: series.metric,
      showSymbol: false,
      connectNulls: false,
      areaStyle: { opacity: 0.12 },
      data: [...series.points]
        .sort((left, right) => left.timestamp.localeCompare(right.timestamp))
        .map((point) => [point.timestamp, point.value]),
    }],
  }
}
