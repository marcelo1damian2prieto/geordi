// Java String.strip() treats U+001C through U+001F as whitespace.
// eslint-disable-next-line no-control-regex
const javaWhitespaceAtEnds = /^[\u0009-\u000d\u001c-\u001f\u0020\u1680\u2000-\u2006\u2008-\u200a\u2028\u2029\u205f\u3000]+|[\u0009-\u000d\u001c-\u001f\u0020\u1680\u2000-\u2006\u2008-\u200a\u2028\u2029\u205f\u3000]+$/gu

export function stripJavaWhitespace(value: string): string {
  return value.replace(javaWhitespaceAtEnds, '')
}

export function hasAtMostCodePoints(value: string, maximum: number): boolean {
  return Array.from(value).length <= maximum
}
