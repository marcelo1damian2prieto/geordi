import { useQueries, useQuery } from '@tanstack/react-query'
import { getSloEvaluation, getSlos, type SloDefinition } from '../../api/slos'

export function useSlos() {
  return useQuery({ queryKey: ['slos', 'list'], queryFn: getSlos })
}

export function sloEvaluationQueryKey(definition: SloDefinition) {
  return [
    'slos',
    'evaluation',
    definition.id,
    definition.service.namespace,
    definition.service.name,
    definition.service.environment,
    definition.sliType,
    definition.target,
    definition.window,
    definition.enabled,
  ] as const
}

export function useSloEvaluations(definitions: readonly SloDefinition[]) {
  return useQueries({
    queries: definitions.map((definition) => ({
      queryKey: sloEvaluationQueryKey(definition),
      queryFn: () => getSloEvaluation(definition.id),
      enabled: definition.enabled,
    })),
  })
}
