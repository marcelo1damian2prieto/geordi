import { getJson } from './client'
import { identityParams, rangeParams, type ServiceIdentity, type TimeRange } from './telemetryContext'

export type LogSeverity = 'UNSPECIFIED' | 'TRACE' | 'DEBUG' | 'INFO' | 'WARN' | 'ERROR' | 'FATAL'

export interface LogRecord {
  timestamp: string
  observedTimestamp: string | null
  severity: LogSeverity
  severityText: string | null
  body: string
  service: ServiceIdentity
  traceId: string | null
  spanId: string | null
  attributes: Record<string, string>
}

export interface LogServicesResponse { services: ServiceIdentity[] }
export interface LogSearchResponse { service: ServiceIdentity; range: TimeRange; logs: LogRecord[] }

export interface LogFilters {
  severity?: LogSeverity
  text?: string
  traceId?: string
  spanId?: string
}

export function getLogServices(range: TimeRange) {
  return getJson<LogServicesResponse>(`/api/logs/services?${rangeParams(range).toString()}`)
}

export function searchLogs(service: ServiceIdentity, range: TimeRange, filters: LogFilters, limit = 100) {
  const params = identityParams(service, range)
  if (filters.severity) params.set('severity', filters.severity)
  if (filters.text) params.set('text', filters.text)
  if (filters.traceId) params.set('traceId', filters.traceId)
  if (filters.spanId) params.set('spanId', filters.spanId)
  params.set('limit', String(limit))
  return getJson<LogSearchResponse>(`/api/logs?${params.toString()}`)
}
