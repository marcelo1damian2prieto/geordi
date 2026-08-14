import { Link, useParams, useSearchParams } from 'react-router-dom'
import { ApiError } from '../../api/client'
import { formatDuration } from './tracePresentation'
import { TraceWaterfall } from './TraceWaterfall'
import { useTraceDetail } from './useTraces'
import { contextSearchParams, parseTelemetryContext } from '../../api/telemetryContext'

function detailFailure(error: Error | null) {
  if (error instanceof ApiError && error.status === 400) return 'The trace identifier is invalid.'
  if (error instanceof ApiError && error.status === 404) {
    const problemIdentity = `${error.problem?.type ?? ''} ${error.problem?.title ?? ''}`.toLowerCase()
    return problemIdentity.includes('trace not found')
      ? 'Trace not found.'
      : 'Traces is not enabled for this Geordi deployment.'
  }
  if (error instanceof ApiError && error.status === 502) return 'Trace storage returned an invalid response.'
  if (error instanceof ApiError && error.status === 503) return 'Trace storage is unavailable.'
  if (error instanceof ApiError && error.status === 504) return 'Trace storage timed out.'
  return 'Trace detail is unavailable.'
}

export function TraceDetailPage() {
  const { traceId } = useParams()
  const [searchParams] = useSearchParams()
  const detail = useTraceDetail(traceId)
  const parsedContext = parseTelemetryContext(searchParams)
  const fromInvestigation = searchParams.get('origin') === 'investigate' && parsedContext.status === 'valid'
  const investigationParams = parsedContext.status === 'valid'
    ? contextSearchParams(parsedContext.context.service, parsedContext.context.range)
    : undefined
  const relatedLogsParams = parsedContext.status === 'valid'
    ? contextSearchParams(parsedContext.context.service, parsedContext.context.range)
    : undefined
  relatedLogsParams?.set('traceId', traceId ?? '')
  const traceSearchParams = new URLSearchParams(searchParams)
  traceSearchParams.delete('origin')
  const backTarget = fromInvestigation
    ? `/investigate?${investigationParams!.toString()}`
    : `/traces${traceSearchParams.size > 0 ? `?${traceSearchParams.toString()}` : ''}`
  const backDestination = fromInvestigation ? 'service investigation' : 'trace search'
  const backLabel = fromInvestigation ? '← Back to service investigation' : '← Back to trace search'

  if (detail.isPending) return <main className="state-panel" aria-busy="true">Loading trace detail…</main>

  if (detail.isError) {
    return (
      <main className="state-panel" role="alert">
        <h1>{detailFailure(detail.error)}</h1>
        <p className="state-detail">Return to {backDestination} or retry this request.</p>
        <button type="button" onClick={() => void detail.refetch()}>Retry</button>
        <p><Link to={backTarget}>Back to {backDestination}</Link></p>
      </main>
    )
  }

  const trace = detail.data
  return (
    <main>
      <Link className="back-link" to={backTarget}>{backLabel}</Link>
      <header className="trace-detail-hero">
        <div><p className="eyebrow">Distributed trace</p><h1>{trace.error ? 'Error trace' : 'Trace detail'}</h1><code>{trace.traceId}</code></div>
        <dl className="trace-summary">
          <div><dt>Duration</dt><dd>{formatDuration(trace.durationNanos)}</dd></div>
          <div><dt>Spans</dt><dd>{trace.spanCount}</dd></div>
          <div><dt>Started</dt><dd>{new Date(trace.startTime).toLocaleString()}</dd></div>
          <div><dt>Outcome</dt><dd className={trace.error ? 'trace-error' : 'trace-ok'}>{trace.error ? 'ERROR' : 'OK'}</dd></div>
        </dl>
      </header>
      {relatedLogsParams && <p><Link className="view-traces-link" to={`/logs?${relatedLogsParams.toString()}`}>View related logs</Link></p>}
      <section aria-labelledby="waterfall-heading">
        <div className="section-heading"><h2 id="waterfall-heading">Span waterfall</h2><span>Timing relative to trace start</span></div>
        <TraceWaterfall trace={trace} />
      </section>
    </main>
  )
}
