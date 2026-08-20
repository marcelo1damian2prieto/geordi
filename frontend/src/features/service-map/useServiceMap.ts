import { useQuery } from '@tanstack/react-query'
import { getServiceMap } from '../../api/serviceMap'
import type { ServiceMapUrlContext } from './serviceMapContext'

export function serviceMapQueryKey(context: ServiceMapUrlContext | undefined) {
  return ['service-map', context?.environment, context?.range.from, context?.range.to] as const
}

export function useServiceMap(context: ServiceMapUrlContext | undefined) {
  return useQuery({
    queryKey: serviceMapQueryKey(context),
    queryFn: () => getServiceMap(context!.environment, context!.range),
    enabled: context !== undefined,
  })
}
