import { describe, expect, it } from 'vitest'
import { hasAtMostCodePoints, stripJavaWhitespace } from './acknowledgementInput'

describe('acknowledgement input contract', () => {
  it('uses the Java whitespace set that the acknowledgement service strips', () => {
    expect(stripJavaWhitespace('\u2003 operator \u001c')).toBe('operator')
    expect(stripJavaWhitespace('\u00a0operator\u00a0')).toBe('\u00a0operator\u00a0')
  })

  it('counts Unicode code points rather than UTF-16 code units', () => {
    expect(hasAtMostCodePoints('😀'.repeat(128), 128)).toBe(true)
    expect(hasAtMostCodePoints('😀'.repeat(129), 128)).toBe(false)
  })

  it('applies the bound after server-compatible normalization', () => {
    expect(hasAtMostCodePoints(stripJavaWhitespace(`\u2003${'😀'.repeat(128)}\u2003`), 128)).toBe(true)
  })
})
