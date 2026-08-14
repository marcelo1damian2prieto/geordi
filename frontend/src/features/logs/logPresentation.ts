import type { LogRecord } from '../../api/logs'
import { ApiError } from '../../api/client'

export function logsFailureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 400) return 'The Logs request is invalid.'
  if (error instanceof ApiError && error.status === 404) return 'Logs is not enabled for this Geordi deployment.'
  if (error instanceof ApiError && error.status === 502) return 'Log storage returned an invalid response.'
  if (error instanceof ApiError && error.status === 503) return 'Log storage is unavailable.'
  if (error instanceof ApiError && error.status === 504) return 'Log storage timed out.'
  return 'Log data is unavailable.'
}

export function severityClass(record: LogRecord) {
  return `log-severity log-severity-${record.severity.toLowerCase()}`
}

export function visibleAttributes(attributes: Record<string, string>, limit = 20) {
  return Object.entries(attributes).sort(([left], [right]) => left.localeCompare(right)).slice(0, limit)
}
