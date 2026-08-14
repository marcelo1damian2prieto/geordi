export interface ServiceIdentity {
  name: string
  namespace: string | null
  environment: string
}

export interface TimeRange {
  from: string
  to: string
}

export interface TelemetryContext {
  service: ServiceIdentity
  range: TimeRange
}

export type TelemetryContextParseResult =
  | { status: 'absent' }
  | { status: 'invalid' }
  | { status: 'valid'; context: TelemetryContext }

const contextParameterNames = ['serviceName', 'serviceNamespace', 'environment', 'from', 'to'] as const
const maximumRangeMillis = 6 * 60 * 60 * 1000
const absoluteTimestampPattern = /(?:Z|[+-]\d{2}:\d{2})$/i

export function serviceKey(service: ServiceIdentity) {
  return JSON.stringify([service.namespace, service.name, service.environment])
}

export function serviceLabel(service: ServiceIdentity) {
  const qualifiedName = service.namespace ? `${service.namespace} / ${service.name}` : service.name
  return `${qualifiedName} · ${service.environment}`
}

export function rangeParams(range: TimeRange) {
  return new URLSearchParams({ from: range.from, to: range.to })
}

export function identityParams(service: ServiceIdentity, range: TimeRange) {
  const params = new URLSearchParams()
  params.set('serviceName', service.name)
  if (service.namespace !== null) params.set('serviceNamespace', service.namespace)
  params.set('environment', service.environment)
  params.set('from', range.from)
  params.set('to', range.to)
  return params
}

export function contextSearchParams(service: ServiceIdentity, range: TimeRange) {
  return identityParams(service, range)
}

export function contextFromSearchParams(params: URLSearchParams): Partial<TelemetryContext> {
  const parsed = parseTelemetryContext(params)
  return parsed.status === 'valid' ? parsed.context : {}
}

export function parseTelemetryContext(params: URLSearchParams): TelemetryContextParseResult {
  if (!contextParameterNames.some((name) => params.has(name))) return { status: 'absent' }

  const name = params.get('serviceName')
  const environment = params.get('environment')
  const from = params.get('from')
  const to = params.get('to')
  const namespace = params.get('serviceNamespace')
  if (!name?.trim() || !environment?.trim() || !from || !to) return { status: 'invalid' }
  if (params.has('serviceNamespace') && !namespace?.trim()) return { status: 'invalid' }
  if (!absoluteTimestampPattern.test(from) || !absoluteTimestampPattern.test(to)) return { status: 'invalid' }

  const fromMillis = Date.parse(from)
  const toMillis = Date.parse(to)
  if (!Number.isFinite(fromMillis) || !Number.isFinite(toMillis) || fromMillis >= toMillis) return { status: 'invalid' }
  if (toMillis - fromMillis > maximumRangeMillis) return { status: 'invalid' }

  return {
    status: 'valid',
    context: {
      service: { name: name.trim(), namespace: namespace?.trim() ?? null, environment: environment.trim() },
      range: { from, to },
    },
  }
}
