import { describe, expect, it } from 'vitest'
import type { AlertEpisode, AlertNotificationDelivery } from '../../api/alertHistory'
import type { AlertEvidence } from '../../api/alertEvaluations'
import { episodeStatus, episodeDuration, transitionLabel, investigationTarget, notificationDeliveryLabel, notificationDispositionLabel, notificationTimestamps } from './alertHistoryPresentation'

const open: AlertEpisode = { id: 'a'.repeat(64), policyId: 'p', openedAt: '2026-01-01T00:00:00.123456789Z', closedAt: null, origin: 'M14', durationSeconds: null }
const evidence: AlertEvidence = { service: { name: 'a /&', namespace: null, environment: 'prod' }, window: 'PT5M', range: { from: open.openedAt!, to: '2026-01-01T00:05:00.123456789Z' }, evaluatedAt: open.openedAt!, observedBurnRate: 0 }
describe('historical presentation', () => {
  it('presents ongoing, completed including zero, and legacy without fabricated duration', () => {
    expect(episodeStatus(open)).toBe('OPEN — ongoing')
    expect(episodeDuration(open)).toBe('Duration unavailable while ongoing')
    expect(episodeStatus({ ...open, closedAt: evidence.range.to })).toBe('CLOSED')
    expect(episodeDuration({ ...open, closedAt: evidence.range.to, durationSeconds: 0 })).toBe('0 seconds')
    expect(episodeDuration({ ...open, closedAt: evidence.range.to, durationSeconds: 299 })).toBe('299 seconds')
    const legacy = { ...open, origin: 'PRE_M14_UNKNOWN_START' as const, openedAt: null, closedAt: evidence.range.to }
    expect(episodeStatus(legacy)).toBe('CLOSED — legacy, start unknown')
    expect(episodeDuration(legacy)).toBe('Duration unavailable')
  })
  it('maps canonical wire labels', () => {
    expect(transitionLabel('ALERT_STARTED')).toBe('STARTED')
    expect(transitionLabel('ALERT_RESOLVED')).toBe('RESOLVED')
  })
  it.each([
    ['MATCHED', 'Matched'], ['SUPPRESSED', 'Suppressed'], ['UNROUTED', 'No matching route'], ['NOT_RECORDED', 'Not recorded'],
  ] as const)('maps notification disposition %s without reconstructing it', (value, label) => {
    expect(notificationDispositionLabel(value)).toBe(label)
  })
  it('uses truthful delivery wording and exposes only state-relevant timestamps', () => {
    const createdAt = '2026-01-01T00:00:00.123456789Z'
    const nextAttemptAt = '2026-01-01T00:01:00.123456789Z'
    const completedAt = '2026-01-01T00:02:00.123456789Z'
    const pending: AlertNotificationDelivery = { state: 'PENDING', attempts: 0, createdAt, nextAttemptAt, completedAt: null }
    const leased: AlertNotificationDelivery = { state: 'LEASED', attempts: 1, createdAt, nextAttemptAt: null, completedAt: null }
    const delivered: AlertNotificationDelivery = { state: 'DELIVERED', attempts: 2, createdAt, nextAttemptAt: null, completedAt }
    const failed: AlertNotificationDelivery = { state: 'FAILED', attempts: 3, createdAt, nextAttemptAt: null, completedAt }
    expect(notificationDeliveryLabel(pending)).toBe('Pending')
    expect(notificationDeliveryLabel(leased)).toBe('Leased — completion not recorded; may await reclaim')
    expect(notificationDeliveryLabel(delivered)).toBe('Delivered — Geordi recorded an accepted HTTP response')
    expect(notificationDeliveryLabel(failed)).toBe('Failed — no detailed cause was recorded')
    expect(notificationTimestamps(pending)).toEqual({ createdAt, nextAttemptAt, completedAt: null })
    expect(notificationTimestamps(leased)).toEqual({ createdAt, nextAttemptAt: null, completedAt: null })
    expect(notificationTimestamps(delivered)).toEqual({ createdAt, nextAttemptAt: null, completedAt })
    expect(notificationTimestamps(failed)).toEqual({ createdAt, nextAttemptAt: null, completedAt })
  })
  it.each([null, 'store /&'])('preserves exact evidence identity and nanoseconds for namespace %s', (namespace) => {
    const href = investigationTarget({ ...evidence, service: { ...evidence.service, namespace } })!
    const target = new URL(href, 'http://test')
    expect(target.pathname).toBe('/investigate')
    expect(target.searchParams.get('serviceName')).toBe(evidence.service.name)
    expect(target.searchParams.get('serviceNamespace')).toBe(namespace)
    expect(target.searchParams.get('environment')).toBe('prod')
    expect(target.searchParams.get('from')).toBe(evidence.range.from)
    expect(target.searchParams.get('to')).toBe(evidence.range.to)
  })
  it('rejects null, incompatible ranges and identity that destination would trim', () => {
    expect(investigationTarget(null)).toBeNull()
    expect(investigationTarget({ ...evidence, range: { ...evidence.range, to: '2026-01-02T00:00:00Z' } })).toBeNull()
    expect(investigationTarget({ ...evidence, service: { ...evidence.service, name: ' a' } })).toBeNull()
    expect(investigationTarget({ ...evidence, service: { ...evidence.service, namespace: '' } })).toBeNull()
  })
})
