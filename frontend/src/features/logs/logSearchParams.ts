import type { LogFilters, LogSeverity } from '../../api/logs'

const severities = new Set<LogSeverity>(['UNSPECIFIED', 'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL'])
const traceIdPattern = /^[0-9a-f]{32}$/
const spanIdPattern = /^[0-9a-f]{16}$/

export type LogFiltersParseResult = { status: 'valid'; filters: LogFilters } | { status: 'invalid' }

export function parseLogFilters(params: URLSearchParams): LogFiltersParseResult {
  const severityValue = params.get('severity')
  const textValue = params.get('text')
  const traceId = params.get('traceId')
  const spanId = params.get('spanId')
  if (severityValue !== null && !severities.has(severityValue as LogSeverity)) return { status: 'invalid' }
  if (textValue !== null && (!textValue.trim() || textValue.trim().length > 256)) return { status: 'invalid' }
  if (traceId !== null && !traceIdPattern.test(traceId)) return { status: 'invalid' }
  if (spanId !== null && (!traceId || !spanIdPattern.test(spanId))) return { status: 'invalid' }
  return {
    status: 'valid',
    filters: {
      ...(severityValue ? { severity: severityValue as LogSeverity } : {}),
      ...(textValue ? { text: textValue.trim() } : {}),
      ...(traceId ? { traceId } : {}),
      ...(spanId ? { spanId } : {}),
    },
  }
}

export function appendLogFilters(params: URLSearchParams, filters: LogFilters) {
  if (filters.severity) params.set('severity', filters.severity)
  if (filters.text) params.set('text', filters.text)
  if (filters.traceId) params.set('traceId', filters.traceId)
  if (filters.spanId) params.set('spanId', filters.spanId)
  return params
}
