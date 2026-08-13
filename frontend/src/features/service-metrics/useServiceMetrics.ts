import { keepPreviousData, useQuery } from '@tanstack/react-query'
import type { OperationalMetric, ServiceIdentity, TimeRange } from '../../api/metrics'
import { getMetricSeries, getMetricServices, getMetricsOverview } from '../../api/metrics'

export function useMetricServices(range: TimeRange) {
  return useQuery({
    queryKey: ['metrics', 'services', range.from, range.to],
    queryFn: () => getMetricServices(range),
    placeholderData: keepPreviousData,
  })
}

export function useMetricsOverview(service: ServiceIdentity | undefined, range: TimeRange) {
  return useQuery({
    queryKey: ['metrics', 'overview', service, range.from, range.to],
    queryFn: () => getMetricsOverview(service!, range),
    enabled: service !== undefined,
  })
}

export function useMetricSeries(
  service: ServiceIdentity | undefined,
  range: TimeRange,
  metrics: readonly OperationalMetric[],
) {
  return useQuery({
    queryKey: ['metrics', 'series', service, range.from, range.to, metrics],
    queryFn: () => getMetricSeries(service!, range, metrics),
    enabled: service !== undefined,
  })
}
