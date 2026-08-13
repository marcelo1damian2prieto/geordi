import { useMemo, useState } from 'react'
import { ApiError } from '../../api/client'
import type { ServiceIdentity, TimeRange } from '../../api/metrics'
import { MetricChart } from './MetricChart'
import { metricConcepts, formatMetricValue, seriesMetricIds } from './metricPresentation'
import { useMetricSeries, useMetricServices, useMetricsOverview } from './useServiceMetrics'

type RangePreset = '15m' | '1h' | '6h'
const ranges: Record<RangePreset, number> = { '15m': 15, '1h': 60, '6h': 360 }

function absoluteRange(preset: RangePreset): TimeRange {
  const to = new Date()
  return { from: new Date(to.getTime() - ranges[preset] * 60_000).toISOString(), to: to.toISOString() }
}

function serviceKey(service: ServiceIdentity) {
  return JSON.stringify([service.namespace, service.name, service.environment])
}

function serviceLabel(service: ServiceIdentity) {
  const qualifiedName = service.namespace ? `${service.namespace} / ${service.name}` : service.name
  return `${qualifiedName} · ${service.environment}`
}

function failureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 404) return 'Metrics is not enabled for this Geordi deployment.'
  if (error instanceof ApiError && error.status === 503) return 'Metrics storage is unavailable.'
  return 'Metrics data is unavailable.'
}

export function ServiceMetricsPage() {
  const [preset, setPreset] = useState<RangePreset>('15m')
  const [range, setRange] = useState(() => absoluteRange('15m'))
  const [selectedKey, setSelectedKey] = useState<string>()
  const servicesQuery = useMetricServices(range)
  const services = useMemo(() => servicesQuery.data?.services ?? [], [servicesQuery.data?.services])
  const selected = useMemo(
    () => services.find((service) => serviceKey(service) === selectedKey) ?? services[0],
    [selectedKey, services],
  )
  const overview = useMetricsOverview(selected, range)
  const series = useMetricSeries(selected, range, seriesMetricIds)

  function changeRange(next: RangePreset) {
    setPreset(next)
    setRange(absoluteRange(next))
  }

  function refresh() {
    setRange(absoluteRange(preset))
  }

  if (servicesQuery.isPending) {
    return <main className="state-panel" aria-busy="true">Discovering monitored services…</main>
  }

  if (servicesQuery.isError) {
    return (
      <main className="state-panel" role="alert">
        <p>{failureMessage(servicesQuery.error)}</p>
        <p className="state-detail">Check the Metrics module and its storage connection, then try again.</p>
        <button type="button" onClick={() => void servicesQuery.refetch()}>Retry</button>
      </main>
    )
  }

  if (services.length === 0) {
    return (
      <main className="state-panel">
        <h1>No monitored services found</h1>
        <p className="state-detail">Send OpenTelemetry metrics from a workload, or choose a wider time range.</p>
        <div className="range-control" aria-label="Time range">
          {(Object.keys(ranges) as RangePreset[]).map((candidate) => (
            <button key={candidate} type="button" aria-pressed={preset === candidate} onClick={() => changeRange(candidate)}>{candidate}</button>
          ))}
        </div>
      </main>
    )
  }

  const values = new Map(overview.data?.values.map((value) => [value.metric, value]))
  const returnedSeries = new Map(series.data?.series.map((item) => [item.metric, item]))
  const hasAnyData = values.size > 0 || [...returnedSeries.values()].some((item) => item.points.length > 0)
  const refreshing = servicesQuery.isFetching || overview.isFetching || series.isFetching

  return (
    <main>
      <header className="metrics-hero">
        <div>
          <p className="eyebrow">Service operations</p>
          <h1>Metrics</h1>
        </div>
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
          <button className="refresh-button" type="button" onClick={refresh}>{refreshing ? 'Refreshing…' : 'Refresh'}</button>
        </div>
      </header>

      {(overview.isPending || series.isPending) && <section className="metrics-loading" aria-busy="true">Loading operational metrics…</section>}

      {overview.isError && (
        <section className="inline-state" role="alert">
          <p>{failureMessage(overview.error)} Summary values could not be loaded.</p>
          <button type="button" onClick={() => void overview.refetch()}>Retry summary</button>
        </section>
      )}

      {overview.data && (
        <section aria-labelledby="overview-heading">
          <div className="section-heading"><h2 id="overview-heading">Current overview</h2><span>Range {preset}</span></div>
          <div className="metric-card-grid">
            {metricConcepts.map((concept) => {
              const primary = values.get(concept.primary)
              const secondary = concept.secondary ? values.get(concept.secondary) : undefined
              return (
                <article className="metric-card" key={concept.id}>
                  <h3>{concept.title}</h3>
                  {primary
                    ? <strong>{formatMetricValue(primary.value, primary.unit)}</strong>
                    : <p className="metric-missing">Not reported in this range</p>}
                  {secondary && <small>{formatMetricValue(secondary.value, secondary.unit)} {concept.secondaryLabel}</small>}
                </article>
              )
            })}
          </div>
        </section>
      )}

      {series.isError && (
        <section className="inline-state" role="alert">
          <p>{failureMessage(series.error)} Time series could not be loaded.</p>
          <button type="button" onClick={() => void series.refetch()}>Retry charts</button>
        </section>
      )}

      {series.data && (
        <section aria-labelledby="charts-heading">
          <h2 id="charts-heading">Trends</h2>
          {!hasAnyData && <p className="inline-state">No metrics received for {selected.name} in the last {preset}. Try a wider range or refresh.</p>}
          <div className="chart-grid">
            {metricConcepts.map((concept) => {
              const metricSeries = returnedSeries.get(concept.primary)
              return metricSeries && metricSeries.points.length > 0
                ? <MetricChart key={concept.id} title={concept.title} series={metricSeries} />
                : <article className="metric-chart-card empty-chart" key={concept.id}><h3>{concept.title}</h3><p>Not reported by this service in this range.</p></article>
            })}
          </div>
        </section>
      )}
    </main>
  )
}
