import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  evaluateAlertLifecycle,
  getAlertStates,
  type AlertLifecycleSnapshot,
  type AlertStatesResponse,
} from '../../api/alertLifecycles'
import type { AlertPolicy } from '../../api/alertEvaluations'

export const alertStatesQueryKey = ['alert-lifecycle', 'states'] as const

export function alertLifecyclePolicyKey(policy: AlertPolicy) {
  return [
    'alert-lifecycle',
    'evaluate',
    policy.id,
    policy.name,
    policy.description,
    policy.enabled,
    policy.sloId,
    policy.condition.type,
    policy.condition.threshold,
  ] as const
}

export function useAlertStates() {
  return useQuery({
    queryKey: alertStatesQueryKey,
    queryFn: ({ signal }) => getAlertStates(signal),
  })
}

function replaceExactSnapshot(
  response: AlertStatesResponse | undefined,
  current: AlertLifecycleSnapshot,
) {
  if (!response) return { alertStates: [current] }
  const index = response.alertStates.findIndex((snapshot) => snapshot.policy.id === current.policy.id)
  if (index < 0) return response
  const cachedPolicy = response.alertStates[index].policy
  const currentPolicy = current.policy
  const samePolicy = cachedPolicy.name === currentPolicy.name
    && cachedPolicy.description === currentPolicy.description
    && cachedPolicy.enabled === currentPolicy.enabled
    && cachedPolicy.sloId === currentPolicy.sloId
    && cachedPolicy.condition.type === currentPolicy.condition.type
    && cachedPolicy.condition.threshold === currentPolicy.condition.threshold
  if (!samePolicy) return response
  return {
    alertStates: response.alertStates.map((snapshot, snapshotIndex) => snapshotIndex === index ? current : snapshot),
  }
}

export function useAlertLifecycleEvaluation(policy: AlertPolicy) {
  const queryClient = useQueryClient()
  return useMutation({
    mutationKey: alertLifecyclePolicyKey(policy),
    mutationFn: () => evaluateAlertLifecycle(policy.id),
    onSuccess: (result) => {
      queryClient.setQueryData<AlertStatesResponse>(
        alertStatesQueryKey,
        (response) => replaceExactSnapshot(response, result.current),
      )
    },
  })
}
