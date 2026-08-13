import { Link, useParams, useSearchParams } from 'react-router-dom'
import { ApiError } from '../../api/client'
import { formatDuration } from './tracePresentation'
import { TraceWaterfall } from './TraceWaterfall'
import { useTraceDetail } from './useTraces'

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
  const backTarget = `/traces${searchParams.size > 0 ? `?${searchParams.toString()}` : ''}`

  if (detail.isPending) return <main className="state-panel" aria-busy="true">Loading trace detail…</main>

  if (detail.isError) {
    return (
      <main className="state-panel" role="alert">
        <h1>{detailFailure(detail.error)}</h1>
        <p className="state-detail">Return to trace search or retry this request.</p>
        <button type="button" onClick={() => void detail.refetch()}>Retry</button>
        <p><Link to={backTarget}>Back to trace search</Link></p>
      </main>
    )
  }

  const trace = detail.data
  return (
    <main>
      <Link className="back-link" to={backTarget}>← Back to trace search</Link>
      <header className="trace-detail-hero">
        <div><p className="eyebrow">Distributed trace</p><h1>{trace.error ? 'Error trace' : 'Trace detail'}</h1><code>{trace.traceId}</code></div>
        <dl className="trace-summary">
          <div><dt>Duration</dt><dd>{formatDuration(trace.durationNanos)}</dd></div>
          <div><dt>Spans</dt><dd>{trace.spanCount}</dd></div>
          <div><dt>Started</dt><dd>{new Date(trace.startTime).toLocaleString()}</dd></div>
          <div><dt>Outcome</dt><dd className={trace.error ? 'trace-error' : 'trace-ok'}>{trace.error ? 'ERROR' : 'OK'}</dd></div>
        </dl>
      </header>
      <section aria-labelledby="waterfall-heading">
        <div className="section-heading"><h2 id="waterfall-heading">Span waterfall</h2><span>Timing relative to trace start</span></div>
        <TraceWaterfall trace={trace} />
      </section>
    </main>
  )
}
