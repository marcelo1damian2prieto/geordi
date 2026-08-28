import type {
  AlertLifecycleProcessingOutcome,
  AlertLifecycleState,
  AlertTransitionType,
} from '../../api/alertLifecycles'

export function alertLifecycleStateLabel(state: AlertLifecycleState) {
  return state === 'FIRING' ? 'Firing' : 'Inactive'
}

export function alertTransitionLabel(type: AlertTransitionType) {
  return type === 'ALERT_STARTED' ? 'Alert started' : 'Alert resolved'
}

export function lifecycleOutcomeMessage(
  outcome: AlertLifecycleProcessingOutcome,
  transitionType: AlertTransitionType | null,
) {
  if (transitionType !== null) return `This evaluation produced ${alertTransitionLabel(transitionType).toLowerCase()}.`
  if (outcome === 'STALE_IGNORED') return 'Older evidence was ignored. Lifecycle state did not change.'
  if (outcome === 'DUPLICATE_IGNORED') return 'Duplicate evidence was ignored. Lifecycle state did not change.'
  return 'Evaluation applied. Lifecycle state did not change.'
}
