import { useQueries, useQuery } from '@tanstack/react-query'
import {
  getAlertEvaluation,
  getAlertPolicies,
  type AlertPolicy,
} from '../../api/alertEvaluations'

export function useAlertPolicies() {
  return useQuery({ queryKey: ['alert-policies', 'list'], queryFn: getAlertPolicies })
}

export function alertEvaluationQueryKey(policy: AlertPolicy) {
  return [
    'alert-policies',
    'evaluation',
    policy.id,
    policy.name,
    policy.description,
    policy.enabled,
    policy.sloId,
    policy.condition.type,
    policy.condition.threshold,
  ] as const
}

export function useAlertEvaluations(policies: readonly AlertPolicy[]) {
  return useQueries({
    queries: policies.map((policy) => ({
      queryKey: alertEvaluationQueryKey(policy),
      queryFn: () => getAlertEvaluation(policy.id),
      enabled: policy.enabled,
    })),
  })
}
