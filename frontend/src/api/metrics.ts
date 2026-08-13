import { getJson } from './client'

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

export interface ServiceIdentity {
  name: string
  namespace: string | null
  environment: string
}

export interface TimeRange {
  from: string
  to: string
}

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

function rangeParams(range: TimeRange) {
  return new URLSearchParams({ from: range.from, to: range.to })
}

function identityParams(service: ServiceIdentity, range: TimeRange) {
  const params = rangeParams(range)
  params.set('serviceName', service.name)
  if (service.namespace !== null) params.set('serviceNamespace', service.namespace)
  params.set('environment', service.environment)
  return params
}

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
