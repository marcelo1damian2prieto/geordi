import { Link } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { ApiError } from '../../api/client'
import type { SliType, SloDefinition, SloEvaluation, SloUnavailableReason, SloWindow } from '../../api/slos'
import { contextSearchParams, serviceLabel } from '../../api/telemetryContext'
import { useSloEvaluations, useSlos } from './useSlos'

function formatRatio(value: number) {
  return new Intl.NumberFormat('en-US', { style: 'percent', maximumFractionDigits: 3 }).format(value)
}

function sliLabel(sliType: SliType) {
  return sliType === 'AVAILABILITY' ? 'Availability' : 'Error rate'
}

function windowLabel(window: SloWindow) {
  return ({ PT5M: '5 minutes', PT15M: '15 minutes', PT1H: '1 hour', PT6H: '6 hours' })[window]
}

function unavailableReason(reason: SloUnavailableReason | null) {
  if (reason === null) return 'This objective could not be evaluated.'
  return ({
    DISABLED: 'This objective is disabled.',
    NO_TRAFFIC: 'No traffic in this evaluation window.',
    MISSING_REQUEST_COUNT: 'Request count telemetry is unavailable for this evaluation window.',
    MISSING_ERROR_COUNT: 'Error count telemetry is unavailable for this evaluation window.',
    INVALID_TELEMETRY: 'Telemetry values are invalid for this evaluation.',
    METRICS_UNAVAILABLE: 'Metrics storage is unavailable for this evaluation.',
  })[reason]
}

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

function DefinitionFacts({ definition }: { definition: SloDefinition }) {
  return (
    <dl className="slo-facts">
      <div><dt>Service</dt><dd>{serviceLabel(definition.service)}</dd></div>
      <div><dt>SLI</dt><dd>{sliLabel(definition.sliType)}</dd></div>
      <div><dt>Target</dt><dd>{formatRatio(definition.target)}</dd></div>
      <div><dt>Window</dt><dd>{windowLabel(definition.window)}</dd></div>
    </dl>
  )
}

function SloCard({ definition, evaluation }: { definition: SloDefinition; evaluation: ReturnType<typeof useSloEvaluations>[number] }) {
  if (!definition.enabled) {
    return (
      <article className="slo-card slo-disabled">
        <h2>{definition.name}</h2>
        {definition.description && <p className="state-detail">{definition.description}</p>}
        <DefinitionFacts definition={definition} />
        <p className="slo-not-evaluated">Disabled — not evaluated</p>
      </article>
    )
  }

  if (evaluation.isPending) {
    return (
      <article className="slo-card" aria-busy="true">
        <h2>{definition.name}</h2><DefinitionFacts definition={definition} />
        <p className="state-detail">Evaluating objective…</p>
      </article>
    )
  }

  if (evaluation.isError) {
    return (
      <article className="slo-card">
        <h2>{definition.name}</h2><DefinitionFacts definition={definition} />
        <div className="inline-state" role="alert"><p>{evaluationFailureMessage(evaluation.error)}</p><button type="button" onClick={() => void evaluation.refetch()}>Retry evaluation</button></div>
      </article>
    )
  }

  const result = evaluation.data
  if (!result) return null
  const investigateTarget = `/investigate?${contextSearchParams(result.service, result.range).toString()}`
  return (
    <article className="slo-card">
      <div className="slo-card-heading"><div><h2>{definition.name}</h2>{definition.description && <p className="state-detail">{definition.description}</p>}</div><Status status={result.status} /></div>
      <DefinitionFacts definition={definition} />
      <dl className="slo-facts slo-evaluation-facts">
        <div><dt>Observed</dt><dd>{result.observedValue === null ? 'Unavailable' : formatRatio(result.observedValue)}</dd></div>
        <div><dt>Requests</dt><dd>{result.requestCount === null ? 'Unavailable' : result.requestCount.toLocaleString()}</dd></div>
        <div><dt>Evaluated</dt><dd><time dateTime={result.evaluatedAt}>{new Date(result.evaluatedAt).toLocaleString()}</time></dd></div>
      </dl>
      {result.status === 'UNAVAILABLE' && <p className="slo-reason">{unavailableReason(result.reason)}</p>}
      <Link className="view-traces-link" to={investigateTarget}>Investigate service</Link>
    </article>
  )
}

export function SloPage() {
  const queryClient = useQueryClient()
  const definitions = useSlos()
  const slos = definitions.data?.slos ?? []
  const evaluations = useSloEvaluations(slos)

  async function refreshObjectives() {
    await queryClient.invalidateQueries({ queryKey: ['slos', 'evaluation'] })
    await definitions.refetch()
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
        <button className="refresh-button" type="button" onClick={() => void refreshObjectives()}>{definitions.isFetching ? 'Refreshing…' : 'Refresh objectives'}</button>
      </header>
      <p className="discovery-note">Definitions are managed by this deployment. Current evaluations use their configured whole windows.</p>
      <section className="slo-grid" aria-label="Configured service-level objectives">
        {slos.map((definition, index) => <SloCard key={definition.id} definition={definition} evaluation={evaluations[index]} />)}
      </section>
    </main>
  )
}
