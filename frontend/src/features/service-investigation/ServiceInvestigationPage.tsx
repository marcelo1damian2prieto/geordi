import { useEffect, useMemo, useState } from 'react'
import { useQuery, type UseQueryResult } from '@tanstack/react-query'
import { Link, useSearchParams } from 'react-router-dom'
import { ApiError } from '../../api/client'
import {
  getMetricServices,
  type MetricSeriesResponse,
  type ServiceIdentity,
  type TimeRange,
} from '../../api/metrics'
import { getTraceServices, type TraceSearchResponse, type TraceSummary } from '../../api/traces'
import { getLogServices, type LogSearchResponse } from '../../api/logs'
import {
  contextSearchParams,
  parseTelemetryContext,
  serviceKey,
  serviceLabel,
} from '../../api/telemetryContext'
import { MetricChart } from '../service-metrics/MetricChart'
import {
  formatMetricValue,
  jvmMetricConcepts,
  jvmMetricIds,
  redMetricConcepts,
  redMetricIds,
  type MetricConcept,
} from '../service-metrics/metricPresentation'
import { useMetricSeries } from '../service-metrics/useServiceMetrics'
import { formatDuration } from '../traces/tracePresentation'
import { useTraceSearch } from '../traces/useTraces'
import { latestPoint, recentTraces, slowestRecentTraces } from './investigationPresentation'
import { useLogSearch } from '../logs/useLogs'
import { LogRecordList } from '../logs/LogRecordList'
import { logsFailureMessage } from '../logs/logPresentation'

type RangePreset = '15m' | '1h' | '6h'
type RangeSelection = RangePreset | 'custom'
const ranges: Record<RangePreset, number> = { '15m': 15, '1h': 60, '6h': 360 }

function absoluteRange(preset: RangePreset): TimeRange {
  const to = new Date()
  return { from: new Date(to.getTime() - ranges[preset] * 60_000).toISOString(), to: to.toISOString() }
}

function presetFor(range: TimeRange): RangeSelection {
  const minutes = (Date.parse(range.to) - Date.parse(range.from)) / 60_000
  return (Object.keys(ranges) as RangePreset[]).find((candidate) => ranges[candidate] === minutes) ?? 'custom'
}

function exactServiceUnion(...groups: Array<readonly ServiceIdentity[] | undefined>) {
  const byKey = new Map<string, ServiceIdentity>()
  groups.flatMap((group) => group ?? []).forEach((service) => byKey.set(serviceKey(service), service))
  return [...byKey.values()].sort((left, right) => serviceKey(left).localeCompare(serviceKey(right)))
}

function metricsFailureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 400) return 'The Metrics request is invalid.'
  if (error instanceof ApiError && error.status === 404) return 'Metrics is not enabled for this Geordi deployment.'
  if (error instanceof ApiError && error.status === 503) return 'Metrics storage is unavailable.'
  return 'Metrics data is unavailable.'
}

function tracesFailureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 400) return 'The Trace request is invalid.'
  if (error instanceof ApiError && error.status === 404) return 'Traces is not enabled for this Geordi deployment.'
  if (error instanceof ApiError && error.status === 502) return 'Trace storage returned an invalid response.'
  if (error instanceof ApiError && error.status === 503) return 'Trace storage is unavailable.'
  if (error instanceof ApiError && error.status === 504) return 'Trace storage timed out.'
  return 'Trace data is unavailable.'
}

function discoveryFailureMessage(message: string) {
  return `${message.replace(/\.$/, '')} during service discovery.`
}

function MetricEvidenceSection({
  title,
  loadingText,
  emptyText,
  concepts,
  query,
}: {
  title: string
  loadingText: string
  emptyText: string
  concepts: readonly MetricConcept[]
  query: UseQueryResult<MetricSeriesResponse, Error>
}) {
  const returnedSeries = new Map(query.data?.series.map((series) => [series.metric, series]))
  const hasAnyData = [...returnedSeries.values()].some((series) => series.points.length > 0)

  return (
    <section aria-label={title}>
      <div className="section-heading"><h2>{title}</h2><span>Exact selected interval</span></div>
      {query.isPending && <div className="metrics-loading" aria-busy="true">{loadingText}</div>}
      {query.isError && (
        <div className="inline-state" role="alert">
          <p>{metricsFailureMessage(query.error)}</p>
          <button type="button" onClick={() => void query.refetch()}>Retry {title}</button>
        </div>
      )}
      {query.data && (
        <>
          {!hasAnyData && <p className="inline-state">{emptyText}</p>}
          <div className="metric-card-grid">
            {concepts.map((concept) => {
              const primarySeries = returnedSeries.get(concept.primary)
              const secondarySeries = concept.secondary ? returnedSeries.get(concept.secondary) : undefined
              const primary = primarySeries ? latestPoint(primarySeries.points) : undefined
              const secondary = secondarySeries ? latestPoint(secondarySeries.points) : undefined
              return (
                <article className="metric-card" key={concept.id}>
                  <h3>{concept.title}</h3>
                  {primary && primarySeries
                    ? <strong>{formatMetricValue(primary.value, primarySeries.unit)}</strong>
                    : <p className="metric-missing">No telemetry in this range.</p>}
                  {secondary && secondarySeries && (
                    <small>{formatMetricValue(secondary.value, secondarySeries.unit)} {concept.secondaryLabel}</small>
                  )}
                </article>
              )
            })}
          </div>
          <div className="chart-grid investigation-chart-grid">
            {concepts.map((concept) => {
              const series = returnedSeries.get(concept.primary)
              return series && series.points.length > 0
                ? <MetricChart key={concept.id} title={concept.title} series={series} />
                : <article className="metric-chart-card empty-chart" key={concept.id}><h3>{concept.title}</h3><p>No telemetry in this range.</p></article>
            })}
          </div>
        </>
      )}
    </section>
  )
}

function traceTarget(trace: TraceSummary, service: ServiceIdentity, range: TimeRange) {
  const params = contextSearchParams(service, range)
  params.set('origin', 'investigate')
  return `/traces/${trace.traceId}?${params.toString()}`
}

function TraceEvidenceList({
  traces,
  service,
  range,
  emptyText,
}: {
  traces: readonly TraceSummary[]
  service: ServiceIdentity
  range: TimeRange
  emptyText: string
}) {
  if (traces.length === 0) return <p className="inline-state">{emptyText}</p>
  return (
    <div className="investigation-trace-list">
      {traces.map((trace) => (
        <article key={trace.traceId} className="investigation-trace-row">
          <div><strong>{trace.rootSpanName}</strong><code>{trace.traceId}</code></div>
          <dl>
            <div><dt>Started</dt><dd>{new Date(trace.startTime).toLocaleString()}</dd></div>
            <div><dt>Duration</dt><dd>{formatDuration(trace.durationNanos)}</dd></div>
            <div><dt>Spans</dt><dd>{trace.spanCount}</dd></div>
            <div><dt>Outcome</dt><dd className={trace.error ? 'trace-error' : 'trace-ok'}>{trace.error ? 'CONTAINS ERROR' : 'OK'}</dd></div>
          </dl>
          <Link to={traceTarget(trace, service, range)}>Open trace</Link>
        </article>
      ))}
    </div>
  )
}

function TraceEvidenceSection({
  title,
  subtitle,
  loadingText,
  emptyText,
  query,
  select,
  service,
  range,
}: {
  title: string
  subtitle: string
  loadingText: string
  emptyText: string
  query: UseQueryResult<TraceSearchResponse, Error>
  select: (traces: readonly TraceSummary[]) => readonly TraceSummary[]
  service: ServiceIdentity
  range: TimeRange
}) {
  return (
    <section aria-label={title}>
      <div className="section-heading"><h2>{title}</h2><span>{subtitle}</span></div>
      {query.isPending && <div className="metrics-loading" aria-busy="true">{loadingText}</div>}
      {query.isError && (
        <div className="inline-state" role="alert">
          <p>{tracesFailureMessage(query.error)}</p>
          <button type="button" onClick={() => void query.refetch()}>Retry {title}</button>
        </div>
      )}
      {query.data && <TraceEvidenceList traces={select(query.data.traces)} service={service} range={range} emptyText={emptyText} />}
    </section>
  )
}

function RecentTraceEvidence({
  query,
  service,
  range,
}: {
  query: UseQueryResult<TraceSearchResponse, Error>
  service: ServiceIdentity
  range: TimeRange
}) {
  if (query.isPending) {
    return <section className="metrics-loading" aria-busy="true">Loading recent traces…</section>
  }
  if (query.isError) {
    return (
      <section className="inline-state" role="alert">
        <p>{tracesFailureMessage(query.error)}</p>
        <button type="button" onClick={() => void query.refetch()}>Retry recent traces</button>
      </section>
    )
  }
  return (
    <>
      <section aria-label="Recent traces">
        <div className="section-heading"><h2>Recent traces</h2><span>Newest first, bounded to 50 results</span></div>
        <TraceEvidenceList traces={recentTraces(query.data.traces)} service={service} range={range} emptyText="No recent traces in this range." />
      </section>
      <section aria-label="Slowest among recent results">
        <div className="section-heading"><h2>Slowest among recent results</h2><span>Duration order within the same bounded recent set</span></div>
        <TraceEvidenceList traces={slowestRecentTraces(query.data.traces)} service={service} range={range} emptyText="No slow trace candidates in this range." />
      </section>
    </>
  )
}

function LogsEvidenceSection({
  query,
  service,
  range,
}: {
  query: UseQueryResult<LogSearchResponse, Error>
  service: ServiceIdentity
  range: TimeRange
}) {
  return (
    <section aria-label="Recent logs">
      <div className="section-heading"><h2>Recent logs</h2><span>Newest first, bounded to 5 records</span></div>
      {query.isPending && <div className="metrics-loading" aria-busy="true">Loading recent logs…</div>}
      {query.isError && (
        <div className="inline-state" role="alert">
          <p>{logsFailureMessage(query.error)}</p>
          <button type="button" onClick={() => void query.refetch()}>Retry recent logs</button>
        </div>
      )}
      {query.data && <LogRecordList logs={query.data.logs} emptyText="No recent logs in this range." />}
      <p><Link className="view-traces-link" to={`/logs?${contextSearchParams(service, range).toString()}`}>View all logs</Link></p>
    </section>
  )
}

export function ServiceInvestigationPage() {
  const [searchParams, setSearchParams] = useSearchParams()
  const parsed = useMemo(() => parseTelemetryContext(searchParams), [searchParams])
  const [discoveryRange] = useState(() => absoluteRange('15m'))
  const activeContext = parsed.status === 'valid' ? parsed.context : undefined
  const range = activeContext?.range ?? discoveryRange
  const discoveryEnabled = parsed.status !== 'invalid'
  const metricsServices = useQuery({
    queryKey: ['investigation', 'metrics', 'services', range.from, range.to],
    queryFn: () => getMetricServices(range),
    enabled: discoveryEnabled,
  })
  const traceServices = useQuery({
    queryKey: ['investigation', 'traces', 'services', range.from, range.to],
    queryFn: () => getTraceServices(range),
    enabled: discoveryEnabled,
  })
  const logServices = useQuery({
    queryKey: ['investigation', 'logs', 'services', range.from, range.to],
    queryFn: () => getLogServices(range),
    enabled: discoveryEnabled,
  })
  const services = useMemo(() => exactServiceUnion(
    activeContext ? [activeContext.service] : undefined,
    metricsServices.data?.services,
    traceServices.data?.services,
    logServices.data?.services,
  ), [activeContext, logServices.data?.services, metricsServices.data?.services, traceServices.data?.services])
  const service = activeContext?.service
  const redMetrics = useMetricSeries(service, range, redMetricIds)
  const jvmMetrics = useMetricSeries(service, range, jvmMetricIds)
  const recent = useTraceSearch(service, range, false)
  const errorTraces = useTraceSearch(service, range, true)
  const recentLogs = useLogSearch(service, range, {}, 5)

  useEffect(() => {
    if (parsed.status !== 'absent' || metricsServices.isPending || traceServices.isPending || logServices.isPending || services.length === 0) return
    setSearchParams(contextSearchParams(services[0], discoveryRange), { replace: true })
  }, [discoveryRange, logServices.isPending, metricsServices.isPending, parsed.status, services, setSearchParams, traceServices.isPending])

  if (parsed.status === 'invalid') {
    return (
      <main className="state-panel" role="alert">
        <h1>Invalid investigation context</h1>
        <p className="state-detail">Use a complete service identity and an absolute range no wider than six hours.</p>
        <Link to="/investigate">Start a new investigation</Link>
      </main>
    )
  }

  if (parsed.status === 'absent') {
    const discoveryFinished = !metricsServices.isPending && !traceServices.isPending && !logServices.isPending
    const discoveryFailed = metricsServices.isError || traceServices.isError || logServices.isError
    return (
      <main>
        <header className="metrics-hero"><div><p className="eyebrow">Cross-signal evidence</p><h1>Service investigation</h1></div></header>
        {!discoveryFinished && <section className="metrics-loading" aria-busy="true">Discovering monitored services…</section>}
        {metricsServices.isError && <section className="inline-state" role="alert">{discoveryFailureMessage(metricsFailureMessage(metricsServices.error))}</section>}
        {traceServices.isError && <section className="inline-state" role="alert">{discoveryFailureMessage(tracesFailureMessage(traceServices.error))}</section>}
        {logServices.isError && <section className="inline-state" role="alert">{discoveryFailureMessage(logsFailureMessage(logServices.error))}</section>}
        {discoveryFinished && services.length === 0 && discoveryFailed && (
          <section className="state-panel">
            <h2>Service discovery unavailable</h2>
            <p className="state-detail">No service identity can be selected until at least one provider returns one.</p>
            <button type="button" onClick={() => { void metricsServices.refetch(); void traceServices.refetch(); void logServices.refetch() }}>Retry discovery</button>
          </section>
        )}
        {discoveryFinished && services.length === 0 && !discoveryFailed && (
          <section className="state-panel">
            <h2>No monitored services found</h2>
            <p className="state-detail">Send OpenTelemetry metrics or traces from a workload, then retry.</p>
            <button type="button" onClick={() => { void metricsServices.refetch(); void traceServices.refetch(); void logServices.refetch() }}>Retry discovery</button>
          </section>
        )}
      </main>
    )
  }

  const selectedService = parsed.context.service
  const preset = presetFor(range)

  function updateContext(nextService: ServiceIdentity, nextRange: TimeRange) {
    setSearchParams(contextSearchParams(nextService, nextRange), { replace: true })
  }

  function refresh() {
    void metricsServices.refetch()
    void traceServices.refetch()
    void logServices.refetch()
    void redMetrics.refetch()
    void jvmMetrics.refetch()
    void recent.refetch()
    void errorTraces.refetch()
    void recentLogs.refetch()
  }

  return (
    <main>
      <header className="metrics-hero investigation-hero">
        <div>
          <p className="eyebrow">Cross-signal evidence</p>
          <h1>Service investigation</h1>
          <p className="context-range">{range.from} — {range.to} absolute context</p>
        </div>
        <div className="metrics-controls">
          <label>Service and environment
            <select value={serviceKey(selectedService)} onChange={(event) => {
              const next = services.find((candidate) => serviceKey(candidate) === event.target.value)
              if (next) updateContext(next, range)
            }}>
              {services.map((candidate) => <option key={serviceKey(candidate)} value={serviceKey(candidate)}>{serviceLabel(candidate)}</option>)}
            </select>
          </label>
          <fieldset className="range-control">
            <legend>Time range</legend>
            {(Object.keys(ranges) as RangePreset[]).map((candidate) => (
              <button key={candidate} type="button" aria-pressed={preset === candidate} onClick={() => updateContext(selectedService, absoluteRange(candidate))}>{candidate}</button>
            ))}
          </fieldset>
          <button className="refresh-button" type="button" onClick={refresh}>Refresh</button>
        </div>
      </header>

      {metricsServices.isError && <section className="discovery-note" role="status">{discoveryFailureMessage(metricsFailureMessage(metricsServices.error))} The selected context remains active.</section>}
      {traceServices.isError && <section className="discovery-note" role="status">{discoveryFailureMessage(tracesFailureMessage(traceServices.error))} The selected context remains active.</section>}
      {logServices.isError && <section className="discovery-note" role="status">{discoveryFailureMessage(logsFailureMessage(logServices.error))} The selected context remains active.</section>}

      <MetricEvidenceSection title="RED metrics" loadingText="Loading RED metrics…" emptyText="No RED metrics in this range." concepts={redMetricConcepts} query={redMetrics} />
      <MetricEvidenceSection title="JVM and resources" loadingText="Loading JVM and resource metrics…" emptyText="No JVM or resource telemetry in this range." concepts={jvmMetricConcepts} query={jvmMetrics} />

      <div className="investigation-traces-heading"><p className="eyebrow">Relevant traces</p><h2>Trace evidence</h2></div>
      <RecentTraceEvidence query={recent} service={selectedService} range={range} />
      <TraceEvidenceSection title="Error traces" subtitle="Traces containing provider-reported errors" loadingText="Loading error traces…" emptyText="No error traces in this range." query={errorTraces} select={recentTraces} service={selectedService} range={range} />
      <div className="investigation-traces-heading"><p className="eyebrow">Textual evidence</p><h2>Log evidence</h2></div>
      <LogsEvidenceSection query={recentLogs} service={selectedService} range={range} />
    </main>
  )
}
