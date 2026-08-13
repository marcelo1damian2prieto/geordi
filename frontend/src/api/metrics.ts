import { getJson } from './client'
import { identityParams, rangeParams, type ServiceIdentity, type TimeRange } from './telemetryContext'

export type { ServiceIdentity, TimeRange } from './telemetryContext'

export type OperationalMetric =
  | 'JVM_MEMORY_USED'
  | 'JVM_CPU_UTILIZATION'
  | 'JVM_THREAD_COUNT'
  | 'JVM_GC_DURATION'
  | 'HTTP_REQUEST_RATE'
  | 'HTTP_REQUEST_COUNT'
  | 'HTTP_REQUEST_LATENCY_P95'
  | 'HTTP_ERROR_RATE'
  | 'HTTP_ERROR_COUNT'

export type MetricUnit = 'By' | '1' | '{thread}' | 's' | '{request}/s' | '{request}'

export interface MetricValue {
  metric: OperationalMetric
  unit: MetricUnit
  value: number
  timestamp: string
}

export interface MetricPoint {
  timestamp: string
  value: number
}

export interface MetricSeries {
  metric: OperationalMetric
  unit: MetricUnit
  points: MetricPoint[]
}

export interface ServicesResponse { services: ServiceIdentity[] }
export interface MetricsOverviewResponse { service: ServiceIdentity; range: TimeRange; values: MetricValue[] }
export interface MetricSeriesResponse { service: ServiceIdentity; range: TimeRange; series: MetricSeries[] }

export function getMetricServices(range: TimeRange) {
  return getJson<ServicesResponse>(`/api/metrics/services?${rangeParams(range).toString()}`)
}

export function getMetricsOverview(service: ServiceIdentity, range: TimeRange) {
  return getJson<MetricsOverviewResponse>(`/api/metrics/overview?${identityParams(service, range).toString()}`)
}

export function getMetricSeries(service: ServiceIdentity, range: TimeRange, metrics: readonly OperationalMetric[]) {
  const params = identityParams(service, range)
  metrics.forEach((metric) => params.append('metric', metric))
  return getJson<MetricSeriesResponse>(`/api/metrics/series?${params.toString()}`)
}
