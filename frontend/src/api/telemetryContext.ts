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
  const name = params.get('serviceName')
  const environment = params.get('environment')
  const from = params.get('from')
  const to = params.get('to')
  if (!name || !environment || !from || !to) return {}

  const fromMillis = Date.parse(from)
  const toMillis = Date.parse(to)
  if (!Number.isFinite(fromMillis) || !Number.isFinite(toMillis) || fromMillis >= toMillis) return {}

  return {
    service: { name, namespace: params.get('serviceNamespace'), environment },
    range: { from, to },
  }
}
