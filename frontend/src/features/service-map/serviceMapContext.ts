import type { ServiceIdentity, TimeRange } from '../../api/telemetryContext'

export interface ServiceMapUrlContext {
  environment: string
  range: TimeRange
}

export type ServiceMapContextParseResult =
  | { status: 'absent' }
  | { status: 'invalid' }
  | { status: 'valid'; context: ServiceMapUrlContext }

const maximumRangeMillis = 6 * 60 * 60 * 1000
const absoluteTimestampPattern = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$/i
const contextParameters = ['environment', 'from', 'to'] as const

function isLeapYear(year: number) {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)
}

function isStrictAbsoluteTimestamp(value: string) {
  const match = absoluteTimestampPattern.exec(value)
  if (!match) return false
  const [, yearText, monthText, dayText, hourText, minuteText, secondText, offset] = match
  const year = Number(yearText)
  const month = Number(monthText)
  const day = Number(dayText)
  const hour = Number(hourText)
  const minute = Number(minuteText)
  const second = Number(secondText)
  const days = [31, isLeapYear(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  if (month < 1 || month > 12 || day < 1 || day > days[month - 1]) return false
  if (hour > 23 || minute > 59 || second > 59) return false
  if (offset.toUpperCase() !== 'Z') {
    const offsetHour = Number(offset.slice(1, 3))
    const offsetMinute = Number(offset.slice(4, 6))
    if (offsetHour > 18 || offsetMinute > 59 || (offsetHour === 18 && offsetMinute !== 0)) return false
  }
  return Number.isFinite(Date.parse(value))
}

export function parseServiceMapContext(params: URLSearchParams): ServiceMapContextParseResult {
  if (!contextParameters.some((name) => params.has(name))) return { status: 'absent' }

  const environment = params.get('environment')
  const from = params.get('from')
  const to = params.get('to')
  if (!environment?.trim() || !from || !to) return { status: 'invalid' }
  if (!isStrictAbsoluteTimestamp(from) || !isStrictAbsoluteTimestamp(to)) return { status: 'invalid' }

  const fromMillis = Date.parse(from)
  const toMillis = Date.parse(to)
  if (!Number.isFinite(fromMillis) || !Number.isFinite(toMillis) || fromMillis >= toMillis) return { status: 'invalid' }
  if (toMillis - fromMillis > maximumRangeMillis) return { status: 'invalid' }

  return { status: 'valid', context: { environment: environment.trim(), range: { from, to } } }
}

export function serviceMapSearchParams(context: ServiceMapUrlContext) {
  return new URLSearchParams({
    environment: context.environment,
    from: context.range.from,
    to: context.range.to,
  })
}

export function serviceMapNodeLabel(service: ServiceIdentity) {
  return service.namespace === null ? `${service.name} (no namespace)` : `${service.namespace} / ${service.name}`
}
