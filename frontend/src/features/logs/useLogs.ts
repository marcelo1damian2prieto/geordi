import { useQuery } from '@tanstack/react-query'
import { getLogServices, searchLogs, type LogFilters } from '../../api/logs'
import type { ServiceIdentity, TimeRange } from '../../api/telemetryContext'

export function useLogServices(range: TimeRange, enabled = true) {
  return useQuery({
    queryKey: ['logs', 'services', range.from, range.to],
    queryFn: () => getLogServices(range),
    enabled,
  })
}

export function useLogSearch(
  service: ServiceIdentity | undefined,
  range: TimeRange,
  filters: LogFilters = {},
  limit = 100,
) {
  return useQuery({
    queryKey: [
      'logs', 'search', service?.namespace, service?.name, service?.environment,
      range.from, range.to, filters.severity ?? null, filters.text ?? null,
      filters.traceId ?? null, filters.spanId ?? null, limit,
    ],
    queryFn: () => searchLogs(service!, range, filters, limit),
    enabled: service !== undefined,
  })
}
