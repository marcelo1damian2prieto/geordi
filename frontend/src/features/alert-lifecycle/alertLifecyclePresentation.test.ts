import { describe, expect, it } from 'vitest'
import {
  alertLifecycleStateLabel,
  alertTransitionLabel,
  lifecycleOutcomeMessage,
} from './alertLifecyclePresentation'

describe('alert lifecycle presentation', () => {
  it('keeps state, transition, and processing outcome language distinct', () => {
    expect(alertLifecycleStateLabel('FIRING')).toBe('Firing')
    expect(alertLifecycleStateLabel('INACTIVE')).toBe('Inactive')
    expect(alertTransitionLabel('ALERT_STARTED')).toBe('Alert started')
    expect(alertTransitionLabel('ALERT_RESOLVED')).toBe('Alert resolved')
    expect(lifecycleOutcomeMessage('STALE_IGNORED', null)).toContain('Older evidence')
    expect(lifecycleOutcomeMessage('DUPLICATE_IGNORED', null)).toContain('Duplicate evidence')
  })
})
