import { describe, expect, it } from 'vitest'
import {
  contextFromSearchParams,
  contextSearchParams,
  identityParams,
  parseTelemetryContext,
  serviceKey,
  type ServiceIdentity,
} from './telemetryContext'

const service = { name: 'checkout', namespace: 'store', environment: 'local' } satisfies ServiceIdentity
const range = { from: '2026-08-13T14:45:00.000Z', to: '2026-08-13T15:00:00.000Z' }

describe('telemetry investigation context', () => {
  it('serializes the complete canonical service identity and absolute range', () => {
    expect(contextSearchParams(service, range).toString()).toBe(
      'serviceName=checkout&serviceNamespace=store&environment=local&from=2026-08-13T14%3A45%3A00.000Z&to=2026-08-13T15%3A00%3A00.000Z',
    )
  })

  it('omits a null namespace rather than serializing it as a value', () => {
    const params = identityParams({ ...service, namespace: null }, range)

    expect(params.has('serviceNamespace')).toBe(false)
    expect(serviceKey({ ...service, namespace: null })).toBe('[null,"checkout","local"]')
  })

  it('parses only complete, valid absolute context', () => {
    expect(contextFromSearchParams(contextSearchParams(service, range))).toEqual({ service, range })
    expect(contextFromSearchParams(new URLSearchParams('serviceName=checkout'))).toEqual({})
    expect(contextFromSearchParams(new URLSearchParams(
      'serviceName=checkout&environment=local&from=not-a-date&to=2026-08-13T15:00:00.000Z',
    ))).toEqual({})
  })

  it('distinguishes absent, valid, and malformed investigation context', () => {
    expect(parseTelemetryContext(new URLSearchParams())).toEqual({ status: 'absent' })
    expect(parseTelemetryContext(contextSearchParams(service, range))).toEqual({
      status: 'valid', context: { service, range },
    })
    expect(parseTelemetryContext(new URLSearchParams('serviceName=checkout'))).toEqual({ status: 'invalid' })
    expect(parseTelemetryContext(new URLSearchParams(
      'serviceName=%20&environment=local&from=2026-08-13T14%3A45%3A00.000Z&to=2026-08-13T15%3A00%3A00.000Z',
    ))).toEqual({ status: 'invalid' })
    expect(parseTelemetryContext(new URLSearchParams(
      'serviceName=checkout&serviceNamespace=%20&environment=local&from=2026-08-13T14%3A45%3A00.000Z&to=2026-08-13T15%3A00%3A00.000Z',
    ))).toEqual({ status: 'invalid' })
  })

  it('rejects non-absolute, unordered, and over-six-hour ranges', () => {
    const query = (from: string, to: string) => new URLSearchParams({
      serviceName: 'checkout', environment: 'local', from, to,
    })

    expect(parseTelemetryContext(query('2026-08-13T14:45:00', range.to))).toEqual({ status: 'invalid' })
    expect(parseTelemetryContext(query(range.to, range.from))).toEqual({ status: 'invalid' })
    expect(parseTelemetryContext(query(range.from, range.from))).toEqual({ status: 'invalid' })
    expect(parseTelemetryContext(query('2026-08-13T08:59:59.999Z', range.to))).toEqual({ status: 'invalid' })
    expect(parseTelemetryContext(query('2026-08-13T09:00:00.000Z', range.to)).status).toBe('valid')
  })
})
