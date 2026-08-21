import { useId, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { ApiError } from '../../api/client'
import type { BurnRateStatus, SloDefinition, SloEvaluation } from '../../api/slos'
import { contextSearchParams, serviceLabel } from '../../api/telemetryContext'
import { useSloEvaluations, useSlos } from './useSlos'
import {
  burnRateUnavailableReason,
  formatBurnRate,
  formatRequestCount,
  formatRatio,
  sliLabel,
  sloUnavailableReason,
  targetComparison,
  windowLabel,
} from './sloPresentation'

function failureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 404) return 'SLOs are not enabled for this Geordi deployment.'
  if (error instanceof ApiError && error.status === 503) return 'SLO catalog is unavailable.'
  return 'SLO catalog is unavailable.'
}

function evaluationFailureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 404) return 'SLO evaluation is not available for this objective.'
  return 'SLO evaluation is unavailable.'
}

function Status({ status }: { status: SloEvaluation['status'] }) {
  const label = status === 'MET' ? 'Met' : status === 'BREACHED' ? 'Breached' : 'Unavailable'
  return <span className={`slo-status slo-status-${status.toLowerCase()}`} aria-label={`SLO status: ${label}`}>{status}</span>
}

function BurnAvailability({ status }: { status: BurnRateStatus }) {
  const label = status === 'AVAILABLE' ? 'Available' : 'Unavailable'
  return <span className={`burn-status burn-status-${status.toLowerCase()}`} aria-label={`Burn-rate data status: ${label}`}>{status}</span>
}

function DefinitionFacts({ definition }: { definition: SloDefinition }) {
  return (
    <dl className="slo-facts">
      <div><dt>Service</dt><dd>{serviceLabel(definition.service)}</dd></div>
      <div><dt>SLI</dt><dd>{sliLabel(definition.sliType)}</dd></div>
      <div><dt>Target {targetComparison(definition.sliType)}</dt><dd>{formatRatio(definition.target)}</dd></div>
      <div><dt>Window</dt><dd>{windowLabel(definition.window)}</dd></div>
    </dl>
  )
}

function SloCard({
  definition,
  evaluation,
  catalogFetching,
}: {
  definition: SloDefinition
  evaluation: ReturnType<typeof useSloEvaluations>[number]
  catalogFetching: boolean
}) {
  const headingId = useId()
  if (catalogFetching) {
    return (
      <article className="slo-card" aria-labelledby={headingId} aria-busy="true">
        <h2 id={headingId}>{definition.name}</h2>
        <p className="state-detail" role="status">Refreshing objective and burn-rate evidence…</p>
      </article>
    )
  }

  if (!definition.enabled) {
    return (
      <article className="slo-card slo-disabled" aria-labelledby={headingId}>
        <h2 id={headingId}>{definition.name}</h2>
        {definition.description && <p className="state-detail">{definition.description}</p>}
        <DefinitionFacts definition={definition} />
        <p className="slo-not-evaluated">Disabled — not evaluated</p>
      </article>
    )
  }

  if (evaluation.isFetching) {
    return (
      <article className="slo-card" aria-labelledby={headingId} aria-busy="true">
        <h2 id={headingId}>{definition.name}</h2><DefinitionFacts definition={definition} />
        <p className="state-detail" role="status">Evaluating objective and burn rate…</p>
      </article>
    )
  }

  if (evaluation.isError) {
    return (
      <article className="slo-card" aria-labelledby={headingId}>
        <h2 id={headingId}>{definition.name}</h2><DefinitionFacts definition={definition} />
        <div className="inline-state" role="alert"><p>{evaluationFailureMessage(evaluation.error)}</p><button type="button" onClick={() => void evaluation.refetch()}>Retry evaluation</button></div>
      </article>
    )
  }

  const result = evaluation.data
  if (!result) return null
  const burn = result.burnRateEvaluation
  const investigateTarget = `/investigate?${contextSearchParams(result.service, result.range).toString()}`
  return (
    <article className="slo-card" aria-labelledby={headingId}>
      <div className="slo-card-heading"><div><h2 id={headingId}>{definition.name}</h2>{definition.description && <p className="state-detail">{definition.description}</p>}</div><Status status={result.status} /></div>
      <DefinitionFacts definition={definition} />
      <dl className="slo-facts slo-evaluation-facts">
        <div><dt>Observed {sliLabel(result.sliType).toLowerCase()}</dt><dd>{result.observedValue === null ? 'Unavailable' : formatRatio(result.observedValue)}</dd></div>
        <div><dt>Requests</dt><dd>{result.requestCount === null ? 'Unavailable' : formatRequestCount(result.requestCount)}</dd></div>
        <div><dt>Evaluated</dt><dd><time dateTime={result.evaluatedAt}>{new Date(result.evaluatedAt).toLocaleString()}</time></dd></div>
      </dl>
      {result.status === 'UNAVAILABLE' && <p className="slo-reason">{sloUnavailableReason(result.reason)}</p>}
      <section className="burn-rate-section" aria-labelledby={`${headingId}-burn`}>
        <div className="burn-rate-heading">
          <h3 id={`${headingId}-burn`}>Error-budget burn</h3>
          <BurnAvailability status={burn.status} />
        </div>
        <p className="burn-rate-explanation">Ratios are shown as percentages. Burn rate is a dimensionless multiplier for this evaluation window.</p>
        <dl className="slo-facts burn-rate-facts">
          <div><dt>Allowed bad-event ratio</dt><dd>{formatRatio(burn.allowedBadRatio)}</dd></div>
          <div><dt>Observed bad-event ratio</dt><dd>{burn.observedBadRatio === null ? 'Unavailable' : formatRatio(burn.observedBadRatio)}</dd></div>
          <div><dt>Burn rate</dt><dd>{burn.burnRate === null ? 'Unavailable' : formatBurnRate(burn.burnRate)}</dd></div>
        </dl>
        {burn.status === 'UNAVAILABLE' && <p className="slo-reason">{burnRateUnavailableReason(burn.reason)}</p>}
      </section>
      <section className="evaluation-window" aria-labelledby={`${headingId}-window`}>
        <h3 id={`${headingId}-window`}>Evaluation window</h3>
        <p className="burn-rate-explanation">Exact half-open interval [from, to)</p>
        <dl className="slo-facts evaluation-window-facts">
          <div><dt>From (inclusive)</dt><dd><time dateTime={result.range.from}>{result.range.from}</time></dd></div>
          <div><dt>To (exclusive)</dt><dd><time dateTime={result.range.to}>{result.range.to}</time></dd></div>
        </dl>
      </section>
      <Link className="view-traces-link" to={investigateTarget}>Investigate service</Link>
    </article>
  )
}

export function SloPage() {
  const queryClient = useQueryClient()
  const [refreshing, setRefreshing] = useState(false)
  const definitions = useSlos()
  const slos = definitions.data?.slos ?? []
  const evaluations = useSloEvaluations(slos)
  const evaluationsFetching = evaluations.some((evaluation) => evaluation.isFetching)
  const evidenceFetching = refreshing || definitions.isFetching || evaluationsFetching

  async function refreshObjectives() {
    setRefreshing(true)
    try {
      await definitions.refetch()
      await queryClient.invalidateQueries({ queryKey: ['slos', 'evaluation'] })
    } finally {
      setRefreshing(false)
    }
  }

  if (definitions.isPending) return <main className="state-panel" aria-busy="true">Loading service-level objectives…</main>

  if (definitions.isError) {
    return <main className="state-panel" role="alert"><h1>{failureMessage(definitions.error)}</h1><button type="button" onClick={() => void definitions.refetch()}>Retry</button></main>
  }

  if (slos.length === 0) {
    return <main className="state-panel"><h1>No service-level objectives configured</h1><p className="state-detail">This deployment has no configured SLO definitions.</p><button type="button" onClick={() => void refreshObjectives()}>Refresh objectives</button></main>
  }

  return (
    <main>
      <header className="metrics-hero">
        <div><p className="eyebrow">Deployment-managed reliability objectives</p><h1>Service-level objectives</h1></div>
        <button className="refresh-button" type="button" disabled={evidenceFetching} onClick={() => void refreshObjectives()}>{refreshing || definitions.isFetching ? 'Refreshing definitions…' : evaluationsFetching ? 'Evaluating…' : 'Refresh objectives'}</button>
      </header>
      <p className="discovery-note">Definitions are managed by this deployment. Current evaluations use their configured whole windows.</p>
      <section className="slo-grid" aria-label="Configured service-level objectives">
        {slos.map((definition, index) => <SloCard key={definition.id} definition={definition} evaluation={evaluations[index]} catalogFetching={refreshing || definitions.isFetching} />)}
      </section>
    </main>
  )
}
