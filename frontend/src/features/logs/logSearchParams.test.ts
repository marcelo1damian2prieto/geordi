import { describe, expect, it } from 'vitest'
import { appendLogFilters, parseLogFilters } from './logSearchParams'

describe('Logs URL filters', () => {
  it('parses and serializes the bounded vendor-neutral filters', () => {
    const params = new URLSearchParams({
      severity: 'ERROR', text: ' rejected ', traceId: 'a'.repeat(32), spanId: 'b'.repeat(16),
    })

    expect(parseLogFilters(params)).toEqual({ status: 'valid', filters: {
      severity: 'ERROR', text: 'rejected', traceId: 'a'.repeat(32), spanId: 'b'.repeat(16),
    } })
    expect(appendLogFilters(new URLSearchParams(), {
      severity: 'WARN', text: 'slow', traceId: 'c'.repeat(32),
    }).toString()).toBe(`severity=WARN&text=slow&traceId=${'c'.repeat(32)}`)
  })

  it.each([
    ['severity=NOTICE'],
    ['text=%20'],
    [`traceId=${'A'.repeat(32)}`],
    [`spanId=${'b'.repeat(16)}`],
    [`traceId=${'a'.repeat(32)}&spanId=short`],
  ])('rejects malformed filter %s', (query) => {
    expect(parseLogFilters(new URLSearchParams(query))).toEqual({ status: 'invalid' })
  })
})
