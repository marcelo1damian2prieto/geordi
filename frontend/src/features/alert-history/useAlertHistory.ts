import { useQuery } from '@tanstack/react-query'
import { getAlertEpisode, listAlertEpisodes, type AlertHistoryQuery } from '../../api/alertHistory'
import { ApiError } from '../../api/client'

function retry(failureCount: number, error: Error) {
  return !(error instanceof ApiError && (error.status === 400 || error.status === 404)) && failureCount < 1
}
export function useAlertEpisodes(query: AlertHistoryQuery | undefined) {
  return useQuery({
    queryKey: ['alert-history', 'episodes', query?.from, query?.to, query?.policyId ?? null, query?.state ?? null, query?.limit],
    queryFn: ({ signal }) => listAlertEpisodes(query!, signal),
    enabled: query !== undefined,
    retry,
  })
}
export function useAlertEpisode(selectedEpisodeId: string | undefined) {
  const valid = selectedEpisodeId !== undefined && /^[0-9a-f]{64}$/.test(selectedEpisodeId)
  return useQuery({
    queryKey: ['alert-history', 'episode', selectedEpisodeId ?? null],
    queryFn: ({ signal }) => getAlertEpisode(selectedEpisodeId!, signal),
    enabled: valid,
    retry,
  })
}
