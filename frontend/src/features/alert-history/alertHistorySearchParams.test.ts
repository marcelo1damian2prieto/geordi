import { describe, expect, it } from 'vitest'
import { parseAlertHistorySearchParams, alertHistorySearchParams, last24Hours } from './alertHistorySearchParams'
const bounds = { from: '2026-08-01T00:00:00.123456789Z', to: '2026-09-01T00:00:00.123456789Z' }
const parse = (values: Record<string, string>) => parseAlertHistorySearchParams(new URLSearchParams(values))
describe('history URL contract', () => {
  it('distinguishes absent bounds while preserving valid optional bookmark values', () => {
    expect(parse({})).toMatchObject({ status: 'absent', filters: { limit: 50 } })
    expect(parse({ episodeId: 'a'.repeat(64), policyId: 'x' })).toMatchObject({ status: 'absent', filters: { episodeId: 'a'.repeat(64), policyId: 'x' } })
  })
  it('round trips exact 31 days/nanoseconds and drops unknown parameters', () => {
    const value = parse({ ...bounds, policyId: 'a /&+', state: 'OPEN', limit: '100', episodeId: 'b'.repeat(64), unknown: 'ignored' })
    expect(value.status).toBe('valid')
    if (value.status !== 'valid') throw new Error('Expected valid')
    expect(parseAlertHistorySearchParams(alertHistorySearchParams(value.query))).toEqual(value)
    expect(alertHistorySearchParams(value.query).has('unknown')).toBe(false)
    expect(value.query.from).toBe(bounds.from)
  })
  it.each<Record<string, string>>([
    { to: '2026-09-01T00:00:00.123456790Z' }, { from: bounds.to }, { from: '2026-09-02T00:00:00Z' },
    { from: '' }, { from: '2026-02-30T00:00:00Z' }, { from: '2025-02-29T00:00:00Z' },
    { from: '2026-08-01T24:00:00Z' }, { from: '2026-08-01T00:60:00Z' }, { from: '2026-08-01T00:00:60Z' },
    { from: '2026-08-01T00:00:00.1234567890Z' }, { from: '2026-08-01T00:00:00+00:00' },
    { from: '2026-13-01T00:00:00Z' }, { from: '2026-00-01T00:00:00Z' }, { from: '2026-08-00T00:00:00Z' },
    { state: 'open' }, { state: '' }, { limit: '0' }, { limit: '101' }, { limit: '1.5' }, { limit: '' },
    { policyId: ' ' }, { episodeId: 'A'.repeat(64) }, { episodeId: 'a'.repeat(63) }, { episodeId: '' },
  ])('rejects invalid URL without repair: %j', (invalid) => expect(parse({ ...bounds, ...invalid })).toMatchObject({ status: 'invalid' }))
  it('rejects partial bounds and invalid optional values even without bounds', () => {
    expect(parse({ from: bounds.from })).toMatchObject({ status: 'invalid' })
    expect(parse({ to: bounds.to })).toMatchObject({ status: 'invalid' })
    expect(parse({ state: 'bad' })).toMatchObject({ status: 'invalid' })
  })
  it.each(['from', 'to', 'policyId', 'state', 'limit', 'episodeId'])('rejects duplicate %s', (name) => {
    const params = new URLSearchParams(bounds)
    params.append(name, 'x'); params.append(name, 'x')
    expect(parseAlertHistorySearchParams(params).status).toBe('invalid')
  })
  it('accepts leap days and closed state with minimum limit', () => expect(parse({ from: '2024-02-29T00:00:00Z', to: '2024-03-01T00:00:00Z', state: 'CLOSED', limit: '1' }).status).toBe('valid'))
  it('anchors a default pair to a single supplied clock sample', () => expect(last24Hours(Date.parse('2026-09-07T12:00:00Z'))).toEqual({ from: '2026-09-06T12:00:00.000Z', to: '2026-09-07T12:00:00.000Z', limit: 50 }))
})
