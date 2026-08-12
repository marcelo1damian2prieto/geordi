import { useQuery } from '@tanstack/react-query'
import { getPlatformOverview } from '../../api/platform'

export const platformOverviewQueryKey = ['platform-overview'] as const

export function usePlatformOverview() {
  return useQuery({
    queryKey: platformOverviewQueryKey,
    queryFn: getPlatformOverview,
  })
}
