import type { TraceDetailResponse, TraceSpan } from '../../api/traces'
import { formatDuration, presentSpans } from './tracePresentation'

function serviceName(span: TraceSpan) {
  return span.service.namespace ? `${span.service.namespace} / ${span.service.name}` : span.service.name
}

function httpSummary(span: TraceSpan) {
  if (!span.http) return null
  const target = span.http.route ?? span.http.path
  return [span.http.requestMethod, target, span.http.responseStatusCode].filter((value) => value !== null).join(' ')
}

export function TraceWaterfall({ trace }: { trace: TraceDetailResponse }) {
  const spans = presentSpans(trace.spans, trace.durationNanos)

  return (
    <div className="waterfall-scroll">
      <table className="waterfall-table">
        <thead><tr><th scope="col">Span</th><th scope="col">Service</th><th scope="col">Status</th><th scope="col">Duration</th><th scope="col">Timeline</th></tr></thead>
        <tbody>
          {spans.map(({ span, depth, leftPercent, widthPercent }) => {
            const http = httpSummary(span)
            return (
              <tr key={span.spanId}>
                <th scope="row">
                  <span className="span-name" style={{ paddingInlineStart: `${depth * 18}px` }}>{span.name}</span>
                  <small>{span.kind}{http ? ` · ${http}` : ''}</small>
                </th>
                <td>{serviceName(span)}<small>{span.service.environment ?? 'Environment unknown'}</small></td>
                <td>
                  <span className={span.error ? 'trace-error' : 'trace-ok'}>{span.error ? 'ERROR' : span.status}</span>
                  {span.errorType && <small>{span.errorType}</small>}
                </td>
                <td>{formatDuration(span.durationNanos)}</td>
                <td>
                  <div className="waterfall-track">
                    <span
                      className={`waterfall-bar${span.error ? ' waterfall-bar-error' : ''}`}
                      style={{ left: `${leftPercent}%`, width: `${widthPercent}%` }}
                      aria-label={`${span.name} starts at ${formatDuration(span.startOffsetNanos)} and lasts ${formatDuration(span.durationNanos)}`}
                    />
                  </div>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
