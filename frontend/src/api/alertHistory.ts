import { getJson } from './client'
import type { AlertEvaluation } from './alertEvaluations'
import type { AlertLifecycleState, AlertTransitionType } from './alertLifecycles'

export type AlertEpisodeState = 'OPEN' | 'CLOSED'
export interface AlertEpisode {
  id: string
  policyId: string
  openedAt: string | null
  closedAt: string | null
  origin: 'M14' | 'PRE_M14_UNKNOWN_START'
  durationSeconds: number | null
}
export interface AlertTransitionHistory {
  id: string
  episodeId: string
  policyId: string
  type: AlertTransitionType
  previousState: AlertLifecycleState
  currentState: AlertLifecycleState
  occurredAt: string
  evaluation: AlertEvaluation
}
export interface AlertEpisodesResponse { alertEpisodes: AlertEpisode[] }
export interface AlertEpisodeDetailResponse { episode: AlertEpisode; transitions: AlertTransitionHistory[] }
export interface AlertHistoryQuery { from: string; to: string; policyId?: string; state?: AlertEpisodeState; limit: number }

export function listAlertEpisodes(query: AlertHistoryQuery, signal?: AbortSignal) {
  const params = new URLSearchParams({ from: query.from, to: query.to, limit: String(query.limit) })
  if (query.policyId !== undefined) params.set('policyId', query.policyId)
  if (query.state !== undefined) params.set('state', query.state)
  return getJson<AlertEpisodesResponse>(`/api/alert-episodes?${params.toString()}`, signal)
}
export function getAlertEpisode(episodeId: string, signal?: AbortSignal) {
  return getJson<AlertEpisodeDetailResponse>(`/api/alert-episodes/${encodeURIComponent(episodeId)}`, signal)
}
