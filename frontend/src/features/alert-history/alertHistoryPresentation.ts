import type { AlertEpisode } from '../../api/alertHistory'
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
