import { getJson } from './client'
import { identityParams, rangeParams, type ServiceIdentity, type TimeRange } from './telemetryContext'

export type SpanKind = 'UNSPECIFIED' | 'INTERNAL' | 'SERVER' | 'CLIENT' | 'PRODUCER' | 'CONSUMER'
export type SpanStatus = 'UNSET' | 'OK' | 'ERROR'

export interface TraceSummary {
  traceId: string
  rootSpanName: string
  startTime: string
  durationNanos: number
  spanCount: number
  error: boolean
}

export interface TraceServicesResponse { services: ServiceIdentity[] }
export interface TraceSearchResponse { service: ServiceIdentity; range: TimeRange; traces: TraceSummary[] }

export interface SpanServiceIdentity {
  name: string
  namespace: string | null
  environment: string | null
}

export interface SpanHttpMetadata {
  requestMethod: string | null
  route: string | null
  path: string | null
  responseStatusCode: number | null
  serverAddress: string | null
  serverPort: number | null
}

export interface TraceSpan {
  traceId: string
  spanId: string
  parentSpanId: string | null
  name: string
  service: SpanServiceIdentity
  telemetryOrigin: string | null
  kind: SpanKind
  status: SpanStatus
  startTime: string
  startOffsetNanos: number
  durationNanos: number
  error: boolean
  errorType: string | null
  http: SpanHttpMetadata | null
}

export interface TraceDetailResponse {
  traceId: string
  startTime: string
  durationNanos: number
  spanCount: number
  error: boolean
  spans: TraceSpan[]
}

export function getTraceServices(range: TimeRange) {
  return getJson<TraceServicesResponse>(`/api/traces/services?${rangeParams(range).toString()}`)
}

export function searchTraces(service: ServiceIdentity, range: TimeRange, errorOnly: boolean) {
  const params = identityParams(service, range)
  if (errorOnly) params.set('errorOnly', 'true')
  return getJson<TraceSearchResponse>(`/api/traces?${params.toString()}`)
}

export function getTrace(traceId: string) {
  return getJson<TraceDetailResponse>(`/api/traces/${encodeURIComponent(traceId)}`)
}
