import type { AlertHistoryQuery } from '../../api/alertHistory'

export interface AlertHistorySelection extends AlertHistoryQuery { episodeId?: string }
type OptionalFilters = Pick<AlertHistorySelection, 'policyId' | 'state' | 'limit' | 'episodeId'>
export type AlertHistoryParseResult =
  | { status: 'absent'; filters: OptionalFilters }
  | { status: 'valid'; query: AlertHistorySelection }
  | { status: 'invalid'; message: string }
const recognized = ['from', 'to', 'policyId', 'state', 'limit', 'episodeId'] as const

// Validate the calendar before converting whole seconds; fractional digits never pass through Date.
function instantNanoseconds(value: string): bigint | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$/.exec(value)
  if (!match) return null
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number)
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0)
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  if (month < 1 || month > 12 || day < 1 || day > days[month - 1] || hour > 23 || minute > 59 || second > 59) return null
  const seconds = Date.parse(`${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}Z`) / 1000
  return BigInt(seconds) * 1_000_000_000n + BigInt((match[7] ?? '').padEnd(9, '0'))
}

export function parseAlertHistorySearchParams(params: URLSearchParams): AlertHistoryParseResult {
  const invalid = (message: string): AlertHistoryParseResult => ({ status: 'invalid', message })
  if (recognized.some((name) => params.getAll(name).length > 1)) return invalid('Duplicate alert history parameters are invalid.')
  const policyId = params.get('policyId')
  const state = params.get('state')
  const limit = params.get('limit')
  const episodeId = params.get('episodeId')
  if (policyId !== null && !policyId.trim()) return invalid('Policy ID must not be blank.')
  if (state !== null && state !== 'OPEN' && state !== 'CLOSED') return invalid('State must be OPEN or CLOSED, or omitted for All.')
  if (limit !== null && (!/^\d+$/.test(limit) || Number(limit) < 1 || Number(limit) > 100)) return invalid('Limit must be an integer from 1 to 100.')
  if (episodeId !== null && !/^[0-9a-f]{64}$/.test(episodeId)) return invalid('Episode ID must contain exactly 64 lowercase hexadecimal characters.')
  const filters: OptionalFilters = { limit: limit === null ? 50 : Number(limit), ...(policyId !== null ? { policyId } : {}), ...(state !== null ? { state } : {}), ...(episodeId !== null ? { episodeId } : {}) }
  const from = params.get('from'); const to = params.get('to')
  if (from === null && to === null) return { status: 'absent', filters }
  if (from === null || to === null) return invalid('From and To must both be supplied.')
  const start = instantNanoseconds(from); const end = instantNanoseconds(to)
  if (start === null || end === null) return invalid('Use real UTC dates in RFC3339 Z format, with at most nine fractional digits; offsets are not supported.')
  if (end <= start || end - start > 31n * 24n * 60n * 60n * 1_000_000_000n) return invalid('From must precede To, and the window must not exceed 31 days.')
  return { status: 'valid', query: { from, to, ...filters } }
}

export function alertHistorySearchParams(query: AlertHistorySelection) {
  const params = new URLSearchParams({ from: query.from, to: query.to, limit: String(query.limit) })
  if (query.policyId !== undefined) params.set('policyId', query.policyId)
  if (query.state !== undefined) params.set('state', query.state)
  if (query.episodeId !== undefined) params.set('episodeId', query.episodeId)
  return params
}
export function last24Hours(now: number): AlertHistorySelection {
  return { from: new Date(now - 86_400_000).toISOString(), to: new Date(now).toISOString(), limit: 50 }
}
