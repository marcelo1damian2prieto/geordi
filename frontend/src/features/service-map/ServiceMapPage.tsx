import { type FormEvent, useEffect, useMemo, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { ApiError } from '../../api/client'
import type { ObservedDependency } from '../../api/serviceMap'
import { contextSearchParams, serviceKey, type ServiceIdentity, type TimeRange } from '../../api/telemetryContext'
import { ServiceMapGraph } from './ServiceMapGraph'
import {
  parseServiceMapContext,
  serviceMapNodeLabel,
  serviceMapSearchParams,
  type ServiceMapUrlContext,
} from './serviceMapContext'
import { useServiceMap } from './useServiceMap'

type RangePreset = '15m' | '1h' | '6h'
const ranges: Record<RangePreset, number> = { '15m': 15, '1h': 60, '6h': 360 }

function absoluteRange(preset: RangePreset): TimeRange {
  const to = new Date()
  return { from: new Date(to.getTime() - ranges[preset] * 60_000).toISOString(), to: to.toISOString() }
}

function presetFor(range: TimeRange) {
  const minutes = (Date.parse(range.to) - Date.parse(range.from)) / 60_000
  return (Object.keys(ranges) as RangePreset[]).find((preset) => ranges[preset] === minutes)
}

function failureMessage(error: Error | null) {
  if (error instanceof ApiError && error.status === 400) return 'Invalid service map context'
  if (error instanceof ApiError && error.status === 404) return 'Service Map is not enabled for this Geordi deployment.'
  if (error instanceof ApiError && error.status === 502) return 'Trace storage returned an invalid response.'
  if (error instanceof ApiError && error.status === 503) return 'Trace storage is unavailable.'
  if (error instanceof ApiError && error.status === 504) return 'Trace storage timed out.'
  return 'Service Map is unavailable.'
}

function investigationTarget(node: ServiceIdentity, range: TimeRange) {
  return `/investigate?${contextSearchParams(node, range).toString()}`
}

function evidenceTarget(edge: ObservedDependency, traceId: string, range: TimeRange) {
  const params = contextSearchParams(edge.callee, range)
  params.set('origin', 'service-map')
  return `/traces/${traceId}?${params.toString()}`
}

function edgeKey(edge: ObservedDependency) {
  return `${serviceKey(edge.caller)}->${serviceKey(edge.callee)}`
}

function EnvironmentControl({ environment, onApply }: { environment: string; onApply: (environment: string) => void }) {
  const [draft, setDraft] = useState(environment)

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const next = draft.trim()
    if (next) onApply(next)
  }

  return (
    <form className="service-map-environment" onSubmit={submit}>
      <label htmlFor="service-map-environment">Environment</label>
      <div><input id="service-map-environment" required value={draft} onChange={(event) => setDraft(event.target.value)} /><button type="submit">Apply environment</button></div>
    </form>
  )
}

function NodeControls({ nodes, range }: { nodes: readonly ServiceIdentity[]; range: TimeRange }) {
  return (
    <section className="service-map-controls" aria-labelledby="map-services-heading">
      <div className="section-heading"><h2 id="map-services-heading">Observed services</h2><span>Exact identities</span></div>
      <ul className="service-map-node-list">
        {nodes.map((node) => {
          const label = serviceMapNodeLabel(node)
          return <li key={serviceKey(node)}><Link to={investigationTarget(node, range)}>Investigate {label}</Link></li>
        })}
      </ul>
    </section>
  )
}

function EdgeControls({ edges, range }: { edges: readonly ObservedDependency[]; range: TimeRange }) {
  return (
    <section className="service-map-controls" aria-labelledby="map-dependencies-heading">
      <div className="section-heading"><h2 id="map-dependencies-heading">Observed dependencies</h2><span>Caller → callee</span></div>
      <div className="service-map-edge-list">
        {edges.map((edge) => (
          <article className="service-map-edge" key={edgeKey(edge)}>
            <div>
              <h3>{serviceMapNodeLabel(edge.caller)} → {serviceMapNodeLabel(edge.callee)}</h3>
              <p>{edge.evidenceCount} distinct {edge.evidenceCount === 1 ? 'trace' : 'traces'} observed</p>
            </div>
            <ol aria-label={`Representative trace evidence for ${serviceMapNodeLabel(edge.caller)} to ${serviceMapNodeLabel(edge.callee)}`}>
              {edge.evidence.map((evidence) => (
                <li key={evidence.traceId}>
                  <Link to={evidenceTarget(edge, evidence.traceId, range)}>Open trace {evidence.traceId}</Link>
                  <time dateTime={evidence.observedAt}>{new Date(evidence.observedAt).toLocaleString()}</time>
                </li>
              ))}
            </ol>
          </article>
        ))}
      </div>
    </section>
  )
}

export function ServiceMapPage() {
  const [searchParams, setSearchParams] = useSearchParams()
  const parsed = useMemo(() => parseServiceMapContext(searchParams), [searchParams])
  const [defaultContext] = useState<ServiceMapUrlContext>(() => ({ environment: 'development', range: absoluteRange('15m') }))
  const context = parsed.status === 'valid' ? parsed.context : undefined
  const map = useServiceMap(context)

  useEffect(() => {
    if (parsed.status === 'absent') setSearchParams(serviceMapSearchParams(defaultContext), { replace: true })
  }, [defaultContext, parsed.status, setSearchParams])

  if (parsed.status === 'absent') {
    return <main className="state-panel" aria-busy="true">Preparing service map…</main>
  }

  if (parsed.status === 'invalid') {
    return (
      <main className="state-panel" role="alert">
        <h1>Invalid service map context</h1>
        <p className="state-detail">Use one environment and a complete explicit-offset absolute range no wider than six hours.</p>
        <Link to="/service-map">Use the default context</Link>
      </main>
    )
  }

  function updateContext(next: ServiceMapUrlContext) {
    setSearchParams(serviceMapSearchParams(next), { replace: true })
  }

  const activeContext = parsed.context
  const activePreset = presetFor(activeContext.range)

  return (
    <main>
      <header className="metrics-hero service-map-hero">
        <div>
          <p className="eyebrow">Trace-derived topology</p>
          <h1>Service map</h1>
          <p className="context-range">{activeContext.range.from} — {activeContext.range.to} absolute context</p>
        </div>
        <div className="metrics-controls">
          <EnvironmentControl key={activeContext.environment} environment={activeContext.environment} onApply={(environment) => updateContext({ environment, range: activeContext.range })} />
          <fieldset className="range-control">
            <legend>Time range</legend>
            {(Object.keys(ranges) as RangePreset[]).map((preset) => (
              <button key={preset} type="button" aria-pressed={activePreset === preset} onClick={() => updateContext({ environment: activeContext.environment, range: absoluteRange(preset) })}>{preset}</button>
            ))}
          </fieldset>
          <button className="refresh-button" type="button" onClick={() => void map.refetch()}>{map.isFetching && !map.isPending ? 'Refreshing…' : 'Refresh'}</button>
        </div>
      </header>

      <p className="service-map-caveat">Observed from available monitored trace evidence in this range. Sampling, retention, instrumentation, and query bounds can omit dependencies.</p>

      {map.isPending && <section className="metrics-loading" aria-busy="true">Loading observed dependencies…</section>}

      {map.isError && (
        <section className="state-panel service-map-state" role="alert">
          <h2>{failureMessage(map.error)}</h2>
          <p className="state-detail">Check the Service Map capability and trace storage, then try again.</p>
          <button type="button" onClick={() => void map.refetch()}>Retry</button>
        </section>
      )}

      {!map.isError && map.data?.truncated && (
        <section className="service-map-warning" role="status">
          This result is bounded and incomplete. It must not be read as the complete service architecture.
        </section>
      )}

      {!map.isError && map.data && map.data.nodes.length === 0 && map.data.edges.length === 0 && (
        <section className="state-panel service-map-state">
          <h2>No observed dependencies</h2>
          <p className="state-detail">No qualifying direct service calls were found in this interval. This does not prove that no dependency exists.</p>
        </section>
      )}

      {!map.isError && map.data && (map.data.nodes.length > 0 || map.data.edges.length > 0) && (
        <>
          <section aria-labelledby="dependency-graph-heading">
            <div className="section-heading"><h2 id="dependency-graph-heading">Dependency graph</h2><span>{map.data.nodes.length} services · {map.data.edges.length} directed dependencies</span></div>
            <ServiceMapGraph nodes={map.data.nodes} edges={map.data.edges} nodeCount={map.data.nodes.length} edgeCount={map.data.edges.length} />
          </section>
          <NodeControls nodes={map.data.nodes} range={activeContext.range} />
          <EdgeControls edges={map.data.edges} range={activeContext.range} />
        </>
      )}
    </main>
  )
}
