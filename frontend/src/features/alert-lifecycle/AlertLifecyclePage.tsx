import { useId } from 'react'
import { useIsMutating } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import type { AlertEvidence, AlertEvaluation, AlertPolicy } from '../../api/alertEvaluations'
import type { AlertLifecycleSnapshot } from '../../api/alertLifecycles'
import { ApiError } from '../../api/client'
import { contextSearchParams, serviceLabel } from '../../api/telemetryContext'
import {
  alertConditionLabel,
  alertStatusLabel,
  alertUnavailableReason,
  alertWindowLabel,
  formatAlertBurnRate,
} from '../alert-evaluations/alertEvaluationPresentation'
import {
  alertLifecycleStateLabel,
  lifecycleOutcomeMessage,
} from './alertLifecyclePresentation'
import {
  useAlertLifecycleEvaluation,
  useAlertStates,
} from './useAlertLifecycles'

function statesFailureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 404) return 'Alert lifecycle is not enabled for this Geordi deployment.'
  return 'Alert lifecycle state is unavailable.'
}

function evaluationFailureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 404) return 'This alert policy is no longer available.'
  if (error instanceof ApiError && error.status === 409) return 'Lifecycle identity conflicts with the configured policy or evidence.'
  return 'Alert lifecycle evaluation is unavailable.'
}

function PolicyFacts({ policy }: { policy: AlertPolicy }) {
  return (
    <dl className="alert-evaluation-facts">
      <div><dt>Policy ID</dt><dd><code>{policy.id}</code></dd></div>
      <div><dt>Referenced SLO</dt><dd><code>{policy.sloId}</code></dd></div>
      <div><dt>Condition</dt><dd>{alertConditionLabel(policy.condition.type)} {formatAlertBurnRate(policy.condition.threshold)}</dd></div>
    </dl>
  )
}

function TimeValue({ value, empty = 'Not yet' }: { value: string | null; empty?: string }) {
  return value === null ? <>{empty}</> : <time dateTime={value}>{new Date(value).toLocaleString()}</time>
}

function LifecycleStatus({ state }: { state: AlertLifecycleSnapshot['state'] }) {
  return (
    <span
      className={`alert-lifecycle-status alert-lifecycle-status-${state.toLowerCase()}`}
      aria-label={`Alert lifecycle state: ${alertLifecycleStateLabel(state)}`}
    >
      {state}
    </span>
  )
}

function EvaluationStatus({ status }: { status: AlertEvaluation['status'] }) {
  return (
    <span
      className={`alert-evaluation-status alert-evaluation-status-${status.toLowerCase().replaceAll('_', '-')}`}
      aria-label={`Latest evaluation status: ${alertStatusLabel(status)}`}
    >
      {status}
    </span>
  )
}

function EvidenceFacts({ evidence, headingId }: { evidence: AlertEvidence; headingId: string }) {
  return (
    <section className="alert-evidence" aria-labelledby={headingId}>
      <h4 id={headingId}>Canonical evaluation evidence</h4>
      <dl className="alert-evaluation-facts">
        <div><dt>Service</dt><dd>{serviceLabel(evidence.service)}</dd></div>
        <div><dt>Window</dt><dd>{alertWindowLabel(evidence.window)}</dd></div>
        <div><dt>Evaluated</dt><dd><TimeValue value={evidence.evaluatedAt} /></dd></div>
        <div><dt>Observed burn rate</dt><dd>{evidence.observedBurnRate === null ? 'Unavailable' : formatAlertBurnRate(evidence.observedBurnRate)}</dd></div>
      </dl>
      <p className="alert-evaluation-explanation">Exact half-open interval [from, to)</p>
      <dl className="alert-evaluation-facts alert-evaluation-window-facts">
        <div><dt>From (inclusive)</dt><dd><time dateTime={evidence.range.from}>{evidence.range.from}</time></dd></div>
        <div><dt>To (exclusive)</dt><dd><time dateTime={evidence.range.to}>{evidence.range.to}</time></dd></div>
      </dl>
    </section>
  )
}

function unavailableExplanation(snapshot: AlertLifecycleSnapshot) {
  if (snapshot.policy.enabled === false) {
    return `Policy disabled — lifecycle state is frozen as ${snapshot.state}. Disabling does not indicate recovery.`
  }
  return snapshot.state === 'FIRING'
    ? 'Current evidence is unavailable. Lifecycle state remains FIRING.'
    : 'Current evidence is unavailable. No alert was started.'
}

function investigationEvidence(snapshot: AlertLifecycleSnapshot) {
  const latestEvidence = snapshot.latestEvaluation?.evidence ?? null
  const retainedActiveEvidence = snapshot.state === 'FIRING'
    && (!snapshot.policy.enabled || snapshot.latestEvaluation?.status === 'UNAVAILABLE')
    ? snapshot.activeEvidence
    : null
  return retainedActiveEvidence === null
    ? { evidence: latestEvidence, retained: false }
    : { evidence: retainedActiveEvidence, retained: true }
}

function AlertLifecycleCard({ snapshot }: { snapshot: AlertLifecycleSnapshot }) {
  const headingId = useId()
  const evaluation = useAlertLifecycleEvaluation(snapshot.policy)

  if (evaluation.isPending) {
    return (
      <article className="alert-evaluation-card" aria-labelledby={headingId} aria-busy="true">
        <h2 id={headingId}>{snapshot.policy.name}</h2>
        <PolicyFacts policy={snapshot.policy} />
        <p className="state-detail" role="status">Evaluating canonical evidence and applying lifecycle state…</p>
      </article>
    )
  }

  const latestEvaluation = snapshot.latestEvaluation
  const investigation = investigationEvidence(snapshot)
  const investigateTarget = investigation.evidence === null
    ? null
    : `/investigate?${contextSearchParams(investigation.evidence.service, investigation.evidence.range).toString()}`

  return (
    <article className="alert-evaluation-card" aria-labelledby={headingId}>
      <div className="alert-evaluation-card-heading">
        <div>
          <h2 id={headingId}>{snapshot.policy.name}</h2>
          {snapshot.policy.description && <p className="state-detail">{snapshot.policy.description}</p>}
        </div>
        <LifecycleStatus state={snapshot.state} />
      </div>
      <PolicyFacts policy={snapshot.policy} />

      <section className="alert-lifecycle-section" aria-labelledby={`${headingId}-state`}>
        <h3 id={`${headingId}-state`}>Lifecycle state</h3>
        {!snapshot.initialized && <p className="alert-evaluation-reason">No lifecycle evaluation recorded. The initial state is INACTIVE.</p>}
        {snapshot.policy.enabled === false && <p className="alert-evaluation-reason">{unavailableExplanation(snapshot)}</p>}
        <dl className="alert-evaluation-facts">
          <div><dt>Current state</dt><dd>{snapshot.state}</dd></div>
          <div><dt>Started at</dt><dd><TimeValue value={snapshot.startedAt} /></dd></div>
          <div><dt>Resolved at</dt><dd><TimeValue value={snapshot.resolvedAt} /></dd></div>
          <div><dt>Last state change</dt><dd><TimeValue value={snapshot.lastStateChangeAt} /></dd></div>
          <div><dt>Last processed</dt><dd><TimeValue value={snapshot.lastProcessedAt} /></dd></div>
          <div><dt>Last canonical evidence</dt><dd><TimeValue value={snapshot.lastEvidenceAt} /></dd></div>
        </dl>
        {snapshot.latestTransition && (
          <p className="alert-lifecycle-transition">
            Latest recorded transition: <strong>{snapshot.latestTransition.type}</strong>{' '}
            (<TimeValue value={snapshot.latestTransition.occurredAt} />)
          </p>
        )}
      </section>

      <section className="alert-lifecycle-section" aria-labelledby={`${headingId}-evaluation`}>
        <div className="alert-evaluation-card-heading">
          <h3 id={`${headingId}-evaluation`}>Latest condition evaluation</h3>
          {latestEvaluation && <EvaluationStatus status={latestEvaluation.status} />}
        </div>
        {latestEvaluation === null && <p className="alert-evaluation-reason">No condition evaluation has been processed.</p>}
        {latestEvaluation && (
          <>
            <dl className="alert-evaluation-facts">
              <div><dt>Evaluation</dt><dd>{alertStatusLabel(latestEvaluation.status)}</dd></div>
              <div><dt>Observed burn rate</dt><dd>{latestEvaluation.evidence?.observedBurnRate == null ? 'Unavailable' : formatAlertBurnRate(latestEvaluation.evidence.observedBurnRate)}</dd></div>
            </dl>
            {latestEvaluation.status === 'UNAVAILABLE' && (
              <div className="alert-evaluation-reason">
                <p>{alertUnavailableReason(latestEvaluation.reason)}</p>
                <p>{unavailableExplanation(snapshot)}</p>
              </div>
            )}
            {latestEvaluation.evidence && <EvidenceFacts evidence={latestEvaluation.evidence} headingId={`${headingId}-evidence`} />}
          </>
        )}
      </section>

      {evaluation.data && (
        <p className="alert-lifecycle-command-result" role="status">
          {lifecycleOutcomeMessage(evaluation.data.outcome, evaluation.data.transition?.type ?? null)}
        </p>
      )}
      {evaluation.isError && (
        <div className="inline-state" role="alert">
          <p>{evaluationFailureMessage(evaluation.error)}</p>
          <button type="button" onClick={() => evaluation.reset()}>Dismiss</button>
        </div>
      )}
      {snapshot.policy.enabled
        ? <button className="refresh-button alert-lifecycle-evaluate" type="button" onClick={() => evaluation.mutate()}>Evaluate now</button>
        : <p className="alert-evaluation-not-evaluated">Disabled — evaluation command unavailable</p>}
      {investigateTarget && (
        <p>
          <Link className="view-traces-link" to={investigateTarget}>
            {investigation.retained ? 'Investigate retained firing evidence' : 'Investigate latest evaluated window'}
          </Link>
        </p>
      )}
    </article>
  )
}

export function AlertLifecyclePage() {
  const states = useAlertStates()
  const evaluationsPending = useIsMutating({ mutationKey: ['alert-lifecycle', 'evaluate'] }) > 0

  if (states.isPending) return <main className="state-panel" aria-busy="true">Loading alert lifecycle states…</main>

  if (states.isError) {
    return (
      <main className="state-panel" role="alert">
        <h1>{statesFailureMessage(states.error)}</h1>
        <button type="button" onClick={() => void states.refetch()}>Retry</button>
      </main>
    )
  }

  const snapshots = states.data.alertStates
  return (
    <main>
      <header className="metrics-hero">
        <div><p className="eyebrow">Bounded operational alert state</p><h1>Alert lifecycle</h1></div>
        <button
          className="refresh-button"
          type="button"
          disabled={states.isFetching || evaluationsPending}
          onClick={() => void states.refetch()}
        >
          {states.isFetching ? 'Refreshing states…' : 'Refresh states'}
        </button>
      </header>
      <p className="discovery-note">Current lifecycle state, latest canonical condition evaluation, and explicit state transitions remain separate.</p>
      {states.isFetching
        ? <section className="state-panel" aria-busy="true">Refreshing current lifecycle states…</section>
        : snapshots.length === 0
          ? <section className="state-panel"><h2>No alert policies configured</h2><p className="state-detail">This deployment has no lifecycle states to display.</p></section>
          : (
            <section className="alert-evaluation-grid" aria-label="Alert lifecycle states">
              {snapshots.map((snapshot) => <AlertLifecycleCard key={snapshot.policy.id} snapshot={snapshot} />)}
            </section>
          )}
    </main>
  )
}
