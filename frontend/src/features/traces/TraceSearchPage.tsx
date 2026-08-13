import { useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { ApiError } from '../../api/client'
import {
  contextFromSearchParams,
  contextSearchParams,
  serviceKey,
  serviceLabel,
  type TimeRange,
} from '../../api/telemetryContext'
import { formatDuration } from './tracePresentation'
import { useTraceSearch, useTraceServices } from './useTraces'

type RangePreset = '15m' | '1h' | '6h'
type RangeSelection = RangePreset | 'custom'
const ranges: Record<RangePreset, number> = { '15m': 15, '1h': 60, '6h': 360 }

function absoluteRange(preset: RangePreset): TimeRange {
  const to = new Date()
  return { from: new Date(to.getTime() - ranges[preset] * 60_000).toISOString(), to: to.toISOString() }
}

function presetFor(range: TimeRange | undefined): RangeSelection {
  if (!range) return '15m'
  const minutes = (Date.parse(range.to) - Date.parse(range.from)) / 60_000
  return (Object.keys(ranges) as RangePreset[]).find((candidate) => ranges[candidate] === minutes) ?? 'custom'
}

function failureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 400) return 'The trace search request is invalid.'
  if (error instanceof ApiError && error.status === 404) return 'Traces is not enabled for this Geordi deployment.'
  if (error instanceof ApiError && error.status === 502) return 'Trace storage returned an invalid response.'
  if (error instanceof ApiError && error.status === 503) return 'Trace storage is unavailable.'
  if (error instanceof ApiError && error.status === 504) return 'Trace storage timed out.'
  return 'Trace data is unavailable.'
}

export function TraceSearchPage() {
  const [searchParams, setSearchParams] = useSearchParams()
  const [initialContext] = useState(() => contextFromSearchParams(searchParams))
  const [preset, setPreset] = useState<RangeSelection>(() => presetFor(initialContext.range))
  const [range, setRange] = useState<TimeRange>(() => initialContext.range ?? absoluteRange('15m'))
  const [selectedKey, setSelectedKey] = useState(() => initialContext.service ? serviceKey(initialContext.service) : undefined)
  const [errorOnly, setErrorOnly] = useState(() => searchParams.get('errorOnly') === 'true')
  const servicesQuery = useTraceServices(range)
  const discovered = useMemo(() => servicesQuery.data?.services ?? [], [servicesQuery.data?.services])
  const services = useMemo(() => {
    if (!initialContext.service || discovered.some((service) => serviceKey(service) === serviceKey(initialContext.service!))) return discovered
    return [initialContext.service, ...discovered]
  }, [discovered, initialContext.service])
  const selected = useMemo(
    () => services.find((service) => serviceKey(service) === selectedKey) ?? services[0],
    [selectedKey, services],
  )
  const tracesQuery = useTraceSearch(selected, range, errorOnly)

  useEffect(() => {
    if (!selected) return
    const params = contextSearchParams(selected, range)
    if (errorOnly) params.set('errorOnly', 'true')
    setSearchParams(params, { replace: true })
  }, [errorOnly, range, selected, setSearchParams])

  function changeRange(next: RangePreset) {
    setPreset(next)
    setRange(absoluteRange(next))
  }

  function refresh() {
    if (preset === 'custom') {
      void servicesQuery.refetch()
      void tracesQuery.refetch()
    } else {
      setRange(absoluteRange(preset))
    }
  }

  if (servicesQuery.isPending && !initialContext.service) {
    return <main className="state-panel" aria-busy="true">Discovering services with traces…</main>
  }

  if (servicesQuery.isError) {
    return (
      <main className="state-panel" role="alert">
        <p>{failureMessage(servicesQuery.error)}</p>
        <p className="state-detail">Check the Traces module and its storage connection, then try again.</p>
        <button type="button" onClick={() => void servicesQuery.refetch()}>Retry</button>
      </main>
    )
  }

  if (services.length === 0) {
    return (
      <main className="state-panel">
        <h1>No services with traces found</h1>
        <p className="state-detail">Send OpenTelemetry traces from a workload, or choose a wider time range.</p>
        <div className="range-control" aria-label="Time range">
          {(Object.keys(ranges) as RangePreset[]).map((candidate) => (
            <button key={candidate} type="button" aria-pressed={preset === candidate} onClick={() => changeRange(candidate)}>{candidate}</button>
          ))}
        </div>
      </main>
    )
  }

  const contextParams = contextSearchParams(selected, range)
  if (errorOnly) contextParams.set('errorOnly', 'true')

  return (
    <main>
      <header className="metrics-hero">
        <div><p className="eyebrow">Trace investigation</p><h1>Traces</h1></div>
        <div className="metrics-controls">
          <label>Service
            <select value={serviceKey(selected)} onChange={(event) => setSelectedKey(event.target.value)}>
              {services.map((service) => <option key={serviceKey(service)} value={serviceKey(service)}>{serviceLabel(service)}</option>)}
            </select>
          </label>
          <fieldset className="range-control">
            <legend>Time range</legend>
            {(Object.keys(ranges) as RangePreset[]).map((candidate) => (
              <button key={candidate} type="button" aria-pressed={preset === candidate} onClick={() => changeRange(candidate)}>{candidate}</button>
            ))}
          </fieldset>
          <label className="error-filter"><input type="checkbox" checked={errorOnly} onChange={(event) => setErrorOnly(event.target.checked)} /> Errors only</label>
          <button className="refresh-button" type="button" onClick={refresh}>{tracesQuery.isFetching ? 'Refreshing…' : 'Refresh'}</button>
        </div>
      </header>

      {tracesQuery.isPending && <section className="metrics-loading" aria-busy="true">Searching traces…</section>}

      {tracesQuery.isError && (
        <section className="inline-state" role="alert">
          <p>{failureMessage(tracesQuery.error)}</p>
          <button type="button" onClick={() => void tracesQuery.refetch()}>Retry search</button>
        </section>
      )}

      {tracesQuery.data && (
        <section aria-labelledby="trace-results-heading">
          <div className="section-heading"><h2 id="trace-results-heading">Trace results</h2><span>{tracesQuery.data.traces.length} traces</span></div>
          {tracesQuery.data.traces.length === 0
            ? <p className="inline-state">No traces found for {selected.name} in this time range{errorOnly ? ' with errors' : ''}.</p>
            : (
              <div className="trace-list-scroll"><table className="trace-list">
                <thead><tr><th scope="col">Started</th><th scope="col">Root operation</th><th scope="col">Duration</th><th scope="col">Spans</th><th scope="col">Outcome</th></tr></thead>
                <tbody>{tracesQuery.data.traces.map((trace) => (
                  <tr key={trace.traceId}>
                    <td>{new Date(trace.startTime).toLocaleString()}</td>
                    <th scope="row"><Link to={`/traces/${trace.traceId}?${contextParams.toString()}`}>{trace.rootSpanName}</Link><code>{trace.traceId}</code></th>
                    <td>{formatDuration(trace.durationNanos)}</td><td>{trace.spanCount}</td>
                    <td><span className={trace.error ? 'trace-error' : 'trace-ok'}>{trace.error ? 'ERROR' : 'OK'}</span></td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
        </section>
      )}
    </main>
  )
}
