import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import type { LogFilters, LogSeverity } from '../../api/logs'
import {
  contextSearchParams,
  parseTelemetryContext,
  serviceKey,
  serviceLabel,
  type TimeRange,
} from '../../api/telemetryContext'
import { LogRecordList } from './LogRecordList'
import { appendLogFilters, parseLogFilters } from './logSearchParams'
import { useLogSearch, useLogServices } from './useLogs'
import { logsFailureMessage } from './logPresentation'

type RangePreset = '15m' | '1h' | '6h'
type RangeSelection = RangePreset | 'custom'
const ranges: Record<RangePreset, number> = { '15m': 15, '1h': 60, '6h': 360 }
const severities: readonly LogSeverity[] = ['UNSPECIFIED', 'TRACE', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL']

function absoluteRange(preset: RangePreset): TimeRange {
  const to = new Date()
  return { from: new Date(to.getTime() - ranges[preset] * 60_000).toISOString(), to: to.toISOString() }
}

function presetFor(range: TimeRange | undefined): RangeSelection {
  if (!range) return '15m'
  const minutes = (Date.parse(range.to) - Date.parse(range.from)) / 60_000
  return (Object.keys(ranges) as RangePreset[]).find((candidate) => ranges[candidate] === minutes) ?? 'custom'
}

export function LogsPage() {
  const [searchParams, setSearchParams] = useSearchParams()
  const [initialContext] = useState(() => parseTelemetryContext(searchParams))
  const [initialFilters] = useState(() => parseLogFilters(searchParams))
  const invalid = initialContext.status === 'invalid' || initialFilters.status === 'invalid'
  const seededContext = initialContext.status === 'valid' ? initialContext.context : undefined
  const [preset, setPreset] = useState<RangeSelection>(() => presetFor(seededContext?.range))
  const [range, setRange] = useState<TimeRange>(() => seededContext?.range ?? absoluteRange('15m'))
  const [selectedIdentity, setSelectedIdentity] = useState(() => seededContext?.service)
  const [filters, setFilters] = useState<LogFilters>(() => initialFilters.status === 'valid' ? initialFilters.filters : {})
  const [textDraft, setTextDraft] = useState(filters.text ?? '')
  const servicesQuery = useLogServices(range, !invalid)
  const discovered = useMemo(() => servicesQuery.data?.services ?? [], [servicesQuery.data?.services])
  const services = useMemo(() => {
    const carried = selectedIdentity ?? seededContext?.service
    if (!carried || discovered.some((service) => serviceKey(service) === serviceKey(carried))) return discovered
    return [carried, ...discovered]
  }, [discovered, seededContext?.service, selectedIdentity])
  const selected = useMemo(
    () => selectedIdentity
      ? services.find((service) => serviceKey(service) === serviceKey(selectedIdentity)) ?? services[0]
      : services[0],
    [selectedIdentity, services],
  )
  const logsQuery = useLogSearch(invalid ? undefined : selected, range, filters, 100)

  useEffect(() => {
    if (!selected || invalid) return
    setSearchParams(appendLogFilters(contextSearchParams(selected, range), filters), { replace: true })
  }, [filters, invalid, range, selected, setSearchParams])

  if (invalid) {
    return (
      <main className="state-panel" role="alert">
        <h1>Invalid Logs context</h1>
        <p className="state-detail">Use a complete service identity, an absolute range no wider than six hours, and valid bounded filters.</p>
        <Link to="/logs">Start a new Logs search</Link>
      </main>
    )
  }

  function changeRange(next: RangePreset) {
    setPreset(next)
    setRange(absoluteRange(next))
  }

  function submitText(event: FormEvent) {
    event.preventDefault()
    const text = textDraft.trim()
    if (text.length > 256) return
    setFilters((current) => ({ ...current, text: text || undefined }))
  }

  function refresh() {
    if (preset === 'custom') {
      void servicesQuery.refetch()
      void logsQuery.refetch()
    } else setRange(absoluteRange(preset))
  }

  if (!seededContext && servicesQuery.isPending) {
    return <main className="state-panel" aria-busy="true">Discovering services with logs…</main>
  }
  if (!seededContext && servicesQuery.isError) {
    return (
      <main className="state-panel" role="alert">
        <p>{logsFailureMessage(servicesQuery.error)}</p>
        <p className="state-detail">Check the Logs module and its storage connection, then try again.</p>
        <button type="button" onClick={() => void servicesQuery.refetch()}>Retry</button>
      </main>
    )
  }
  if (services.length === 0) {
    return (
      <main className="state-panel">
        <h1>No services with logs found</h1>
        <p className="state-detail">Send OpenTelemetry logs from a workload, or choose a wider time range.</p>
      </main>
    )
  }

  return (
    <main>
      <header className="metrics-hero">
        <div><p className="eyebrow">Operational evidence</p><h1>Logs</h1><p className="context-range">Newest first · up to 100 records</p></div>
        <div className="metrics-controls">
          <label>Service and environment
            <select value={serviceKey(selected)} onChange={(event) => {
              const next = services.find((service) => serviceKey(service) === event.target.value)
              if (next) setSelectedIdentity(next)
            }}>
              {services.map((service) => <option key={serviceKey(service)} value={serviceKey(service)}>{serviceLabel(service)}</option>)}
            </select>
          </label>
          <fieldset className="range-control"><legend>Time range</legend>
            {(Object.keys(ranges) as RangePreset[]).map((candidate) => (
              <button key={candidate} type="button" aria-pressed={preset === candidate} onClick={() => changeRange(candidate)}>{candidate}</button>
            ))}
          </fieldset>
          <label>Severity
            <select value={filters.severity ?? ''} onChange={(event) => setFilters((current) => ({
              ...current, severity: (event.target.value || undefined) as LogSeverity | undefined,
            }))}>
              <option value="">All severities</option>
              {severities.map((severity) => <option key={severity} value={severity}>{severity}</option>)}
            </select>
          </label>
          <form className="log-text-filter" onSubmit={submitText}>
            <label>Message contains<input value={textDraft} maxLength={256} onChange={(event) => setTextDraft(event.target.value)} /></label>
            <button type="submit">Search</button>
          </form>
          <button className="refresh-button" type="button" onClick={refresh}>{logsQuery.isFetching ? 'Refreshing…' : 'Refresh'}</button>
        </div>
      </header>

      {servicesQuery.isError && seededContext && <section className="discovery-note" role="status">{logsFailureMessage(servicesQuery.error)} during service discovery. The selected context remains active.</section>}
      {(filters.traceId || filters.spanId) && (
        <section className="correlation-filter" aria-label="Correlation filter">
          <strong>Correlated logs</strong>
          {filters.traceId && <span>Trace <code>{filters.traceId}</code></span>}
          {filters.spanId && <span>Span <code>{filters.spanId}</code></span>}
          <button type="button" onClick={() => setFilters((current) => ({ ...current, traceId: undefined, spanId: undefined }))}>Clear correlation</button>
        </section>
      )}
      {logsQuery.isPending && <section className="metrics-loading" aria-busy="true">Searching logs…</section>}
      {logsQuery.isError && <section className="inline-state" role="alert"><p>{logsFailureMessage(logsQuery.error)}</p><button type="button" onClick={() => void logsQuery.refetch()}>Retry search</button></section>}
      {logsQuery.data && (
        <section aria-labelledby="log-results-heading">
          <div className="section-heading"><h2 id="log-results-heading">Log records</h2><span>{logsQuery.data.logs.length} records</span></div>
          <LogRecordList logs={logsQuery.data.logs} emptyText={`No logs found for ${selected.name} in this range${filters.severity ? ` with severity ${filters.severity}` : ''}.`} />
        </section>
      )}
    </main>
  )
}
