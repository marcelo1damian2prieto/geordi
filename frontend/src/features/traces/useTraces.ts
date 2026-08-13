import { keepPreviousData, useQuery } from '@tanstack/react-query'
import type { ServiceIdentity, TimeRange } from '../../api/telemetryContext'
import { getTrace, getTraceServices, searchTraces } from '../../api/traces'

export function useTraceServices(range: TimeRange) {
  return useQuery({
    queryKey: ['traces', 'services', range.from, range.to],
    queryFn: () => getTraceServices(range),
    placeholderData: keepPreviousData,
  })
}

export function useTraceSearch(service: ServiceIdentity | undefined, range: TimeRange, errorOnly: boolean) {
  return useQuery({
    queryKey: ['traces', 'search', service, range.from, range.to, errorOnly],
    queryFn: () => searchTraces(service!, range, errorOnly),
    enabled: service !== undefined,
  })
}

export function useTraceDetail(traceId: string | undefined) {
  return useQuery({
    queryKey: ['traces', 'detail', traceId],
    queryFn: () => getTrace(traceId!),
    enabled: traceId !== undefined,
  })
}
