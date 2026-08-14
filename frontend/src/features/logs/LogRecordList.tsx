import type { LogRecord } from '../../api/logs'
import { serviceLabel } from '../../api/telemetryContext'
import { severityClass, visibleAttributes } from './logPresentation'

export function LogRecordList({ logs, emptyText }: { logs: readonly LogRecord[]; emptyText: string }) {
  if (logs.length === 0) return <p className="inline-state">{emptyText}</p>
  return (
    <div className="log-list">
      {logs.map((log, index) => {
        const attributes = visibleAttributes(log.attributes)
        const omitted = Object.keys(log.attributes).length - attributes.length
        return (
          <article className="log-row" key={`${log.timestamp}-${log.traceId ?? ''}-${log.spanId ?? ''}-${index}`}>
            <div className="log-row-summary">
              <time dateTime={log.timestamp}>{new Date(log.timestamp).toLocaleString()}</time>
              <span className={severityClass(log)}>{log.severity}</span>
              <strong>{serviceLabel(log.service)}</strong>
              {log.traceId && <span className="trace-linked">Trace linked</span>}
            </div>
            <p className="log-body">{log.body}</p>
            <details>
              <summary>Log details</summary>
              <dl className="log-detail">
                {log.observedTimestamp && <div><dt>Observed</dt><dd>{log.observedTimestamp}</dd></div>}
                {log.severityText && <div><dt>Severity text</dt><dd>{log.severityText}</dd></div>}
                {log.traceId && <div><dt>Trace ID</dt><dd><code>{log.traceId}</code></dd></div>}
                {log.spanId && <div><dt>Span ID</dt><dd><code>{log.spanId}</code></dd></div>}
                {attributes.map(([key, value]) => <div key={key}><dt>{key}</dt><dd>{value}</dd></div>)}
              </dl>
              {omitted > 0 && <p>{omitted} more attributes not shown.</p>}
            </details>
          </article>
        )
      })}
    </div>
  )
}
