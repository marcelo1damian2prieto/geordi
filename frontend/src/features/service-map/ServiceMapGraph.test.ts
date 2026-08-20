import { describe, expect, it } from 'vitest'
import type { ObservedDependency } from '../../api/serviceMap'
import type { ServiceIdentity } from '../../api/telemetryContext'
import { serviceMapGraphOption } from './serviceMapGraphPresentation'

describe('Service Map graph presentation', () => {
  it('renders telemetry-controlled identities only through canvas rich text', () => {
    const hostile = { name: '<img src=x onerror=alert(1)>', namespace: null, environment: 'development' } satisfies ServiceIdentity
    const safe = { name: 'inventory', namespace: 'store', environment: 'development' } satisfies ServiceIdentity
    const edge = { caller: hostile, callee: safe, evidenceCount: 1, evidence: [] } satisfies ObservedDependency

    const option = serviceMapGraphOption([hostile, safe], [edge], 2, 1)

    expect(option.tooltip.renderMode).toBe('richText')
    expect(option.tooltip.formatter({ dataType: 'node', data: { label: hostile.name } })).toBe(hostile.name)
  })
})
