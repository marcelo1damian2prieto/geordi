import type { AlertEpisode, AlertNotificationDelivery, AlertNotificationDisposition } from '../../api/alertHistory'
import type { AlertEvidence } from '../../api/alertEvaluations'
import type { AlertTransitionType } from '../../api/alertLifecycles'
import { contextSearchParams, parseTelemetryContext } from '../../api/telemetryContext'
import { ApiError } from '../../api/client'

export function episodeStatus(episode: AlertEpisode) {
  if (episode.origin === 'PRE_M14_UNKNOWN_START') return 'CLOSED — legacy, start unknown'
  return episode.closedAt === null ? 'OPEN — ongoing' : 'CLOSED'
}
export function episodeDuration(episode: AlertEpisode) {
  if (episode.origin === 'PRE_M14_UNKNOWN_START') return 'Duration unavailable'
  if (episode.closedAt === null) return 'Duration unavailable while ongoing'
  return episode.durationSeconds === null ? 'Duration unavailable' : `${episode.durationSeconds} seconds`
}
export function transitionLabel(type: AlertTransitionType) {
  return type === 'ALERT_STARTED' ? 'STARTED' : 'RESOLVED'
}
export function notificationDispositionLabel(disposition: AlertNotificationDisposition) {
  switch (disposition) {
    case 'MATCHED': return 'Matched'
    case 'SUPPRESSED': return 'Suppressed'
    case 'UNROUTED': return 'No matching route'
    case 'NOT_RECORDED': return 'Not recorded'
  }
}
export function notificationDeliveryLabel(delivery: AlertNotificationDelivery) {
  switch (delivery.state) {
    case 'PENDING': return 'Pending'
    case 'LEASED': return 'Leased — completion not recorded; may await reclaim'
    case 'DELIVERED': return 'Delivered — Geordi recorded an accepted HTTP response'
    case 'FAILED': return 'Failed — no detailed cause was recorded'
  }
}
export function notificationTimestamps(delivery: AlertNotificationDelivery) {
  if (delivery.state === 'PENDING') return { createdAt: delivery.createdAt, nextAttemptAt: delivery.nextAttemptAt, completedAt: null }
  if (delivery.state === 'LEASED') return { createdAt: delivery.createdAt, nextAttemptAt: null, completedAt: null }
  return { createdAt: delivery.createdAt, nextAttemptAt: null, completedAt: delivery.completedAt }
}
export function investigationTarget(evidence: AlertEvidence | null) {
  if (!evidence?.service || !evidence.range) return null
  const params = contextSearchParams(evidence.service, evidence.range)
  const parsed = parseTelemetryContext(params)
  if (parsed.status !== 'valid') return null
  const { service, range } = parsed.context
  if (service.name !== evidence.service.name || service.namespace !== evidence.service.namespace
    || service.environment !== evidence.service.environment || range.from !== evidence.range.from || range.to !== evidence.range.to) return null
  return `/investigate?${params.toString()}`
}
export function historyFailure(error: Error | null, detail = false) {
  if (error instanceof ApiError && error.status === 400) return 'Invalid alert history request'
  if (error instanceof ApiError && error.status === 404) return detail ? 'Episode not found or history unavailable' : 'Alert history is unavailable or disabled'
  return detail ? 'Episode detail is unavailable' : 'Alert history is unavailable'
}
