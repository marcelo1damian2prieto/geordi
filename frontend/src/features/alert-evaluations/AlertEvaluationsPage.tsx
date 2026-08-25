import { useId, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Link } from 'react-router-dom'
import { ApiError } from '../../api/client'
import type { AlertEvaluation, AlertPolicy } from '../../api/alertEvaluations'
import { contextSearchParams, serviceLabel } from '../../api/telemetryContext'
import {
  alertConditionLabel,
  alertStatusLabel,
  alertUnavailableReason,
  alertWindowLabel,
  formatAlertBurnRate,
} from './alertEvaluationPresentation'
import { useAlertEvaluations, useAlertPolicies } from './useAlertEvaluations'

function catalogFailureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 404) return 'Alert evaluation is not enabled for this Geordi deployment.'
  return 'Alert policy catalog is unavailable.'
}

function evaluationFailureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 404) return 'This alert policy is no longer available.'
  return 'Alert evaluation is unavailable.'
}

function EvaluationStatus({ status }: { status: AlertEvaluation['status'] }) {
  const label = alertStatusLabel(status)
  return (
    <span
      className={`alert-evaluation-status alert-evaluation-status-${status.toLowerCase().replaceAll('_', '-')}`}
      aria-label={`Alert evaluation status: ${label}`}
    >
      {status}
    </span>
  )
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

function AlertPolicyCard({
  policy,
  evaluation,
  catalogFetching,
}: {
  policy: AlertPolicy
  evaluation: ReturnType<typeof useAlertEvaluations>[number]
  catalogFetching: boolean
}) {
  const headingId = useId()

  if (catalogFetching) {
    return (
      <article className="alert-evaluation-card" aria-labelledby={headingId} aria-busy="true">
        <h2 id={headingId}>{policy.name}</h2>
        <p className="state-detail" role="status">Refreshing policy and canonical evidence…</p>
      </article>
    )
  }

  if (!policy.enabled) {
    return (
      <article className="alert-evaluation-card alert-evaluation-disabled" aria-labelledby={headingId}>
        <h2 id={headingId}>{policy.name}</h2>
        {policy.description && <p className="state-detail">{policy.description}</p>}
        <PolicyFacts policy={policy} />
        <p className="alert-evaluation-not-evaluated">Disabled — not evaluated</p>
      </article>
    )
  }

  if (evaluation.isFetching) {
    return (
      <article className="alert-evaluation-card" aria-labelledby={headingId} aria-busy="true">
        <h2 id={headingId}>{policy.name}</h2>
        <PolicyFacts policy={policy} />
        <p className="state-detail" role="status">Evaluating current condition…</p>
      </article>
    )
  }

  if (evaluation.isError) {
    return (
      <article className="alert-evaluation-card" aria-labelledby={headingId}>
        <h2 id={headingId}>{policy.name}</h2>
        <PolicyFacts policy={policy} />
        <div className="inline-state" role="alert">
          <p>{evaluationFailureMessage(evaluation.error)}</p>
          <button type="button" onClick={() => void evaluation.refetch()}>Retry evaluation</button>
        </div>
      </article>
    )
  }

  const result = evaluation.data
  if (!result) return null
  const evidence = result.evidence
  const investigateTarget = evidence
    ? `/investigate?${contextSearchParams(evidence.service, evidence.range).toString()}`
    : null

  return (
    <article className="alert-evaluation-card" aria-labelledby={headingId}>
      <div className="alert-evaluation-card-heading">
        <div>
          <h2 id={headingId}>{result.policyName}</h2>
          {policy.description && <p className="state-detail">{policy.description}</p>}
        </div>
        <EvaluationStatus status={result.status} />
      </div>
      <dl className="alert-evaluation-facts">
        <div><dt>Policy ID</dt><dd><code>{result.policyId}</code></dd></div>
        <div><dt>Referenced SLO</dt><dd><code>{result.sloId}</code></dd></div>
        <div><dt>Condition</dt><dd>{alertConditionLabel(result.condition.type)} {formatAlertBurnRate(result.condition.threshold)}</dd></div>
        <div><dt>Observed burn rate</dt><dd>{evidence?.observedBurnRate === null || evidence === null ? 'Unavailable' : formatAlertBurnRate(evidence.observedBurnRate)}</dd></div>
      </dl>
      {result.status === 'UNAVAILABLE' && <p className="alert-evaluation-reason">{alertUnavailableReason(result.reason)}</p>}
      {evidence && (
        <>
          <section className="alert-evidence" aria-labelledby={`${headingId}-evidence`}>
            <h3 id={`${headingId}-evidence`}>Canonical evidence</h3>
            <dl className="alert-evaluation-facts">
              <div><dt>Service</dt><dd>{serviceLabel(evidence.service)}</dd></div>
              <div><dt>Window</dt><dd>{alertWindowLabel(evidence.window)}</dd></div>
              <div><dt>Evaluated</dt><dd><time dateTime={evidence.evaluatedAt}>{new Date(evidence.evaluatedAt).toLocaleString()}</time></dd></div>
            </dl>
          </section>
          <section className="alert-evidence" aria-labelledby={`${headingId}-window`}>
            <h3 id={`${headingId}-window`}>Evaluation window</h3>
            <p className="alert-evaluation-explanation">Exact half-open interval [from, to)</p>
            <dl className="alert-evaluation-facts alert-evaluation-window-facts">
              <div><dt>From (inclusive)</dt><dd><time dateTime={evidence.range.from}>{evidence.range.from}</time></dd></div>
              <div><dt>To (exclusive)</dt><dd><time dateTime={evidence.range.to}>{evidence.range.to}</time></dd></div>
            </dl>
          </section>
        </>
      )}
      {investigateTarget && <Link className="view-traces-link" to={investigateTarget}>Investigate service</Link>}
    </article>
  )
}

export function AlertEvaluationsPage() {
  const queryClient = useQueryClient()
  const [refreshing, setRefreshing] = useState(false)
  const catalog = useAlertPolicies()
  const policies = catalog.data?.alertPolicies ?? []
  const evaluations = useAlertEvaluations(policies)
  const evaluationsFetching = evaluations.some((evaluation) => evaluation.isFetching)
  const evidenceFetching = refreshing || catalog.isFetching || evaluationsFetching

  async function refreshEvaluations() {
    setRefreshing(true)
    try {
      await catalog.refetch()
      await queryClient.invalidateQueries({ queryKey: ['alert-policies', 'evaluation'] })
    } finally {
      setRefreshing(false)
    }
  }

  if (catalog.isPending) return <main className="state-panel" aria-busy="true">Loading alert policies…</main>

  if (catalog.isError) {
    return <main className="state-panel" role="alert"><h1>{catalogFailureMessage(catalog.error)}</h1><button type="button" onClick={() => void catalog.refetch()}>Retry</button></main>
  }

  if (policies.length === 0) {
    return (
      <main className="state-panel">
        <h1>No alert policies configured</h1>
        <p className="state-detail">This deployment has no configured alert evaluation policies.</p>
        <button type="button" onClick={() => void refreshEvaluations()}>Refresh policies</button>
      </main>
    )
  }

  return (
    <main>
      <header className="metrics-hero">
        <div><p className="eyebrow">Deployment-managed reliability conditions</p><h1>Alert evaluations</h1></div>
        <button className="refresh-button" type="button" disabled={evidenceFetching} onClick={() => void refreshEvaluations()}>
          {refreshing || catalog.isFetching ? 'Refreshing policies…' : evaluationsFetching ? 'Evaluating…' : 'Refresh evaluations'}
        </button>
      </header>
      <p className="discovery-note">Stateless, on-demand comparisons of canonical burn-rate evidence against configured thresholds.</p>
      <section className="alert-evaluation-grid" aria-label="Configured alert evaluation policies">
        {policies.map((policy, index) => (
          <AlertPolicyCard
            key={policy.id}
            policy={policy}
            evaluation={evaluations[index]}
            catalogFetching={refreshing || catalog.isFetching}
          />
        ))}
      </section>
    </main>
  )
}
