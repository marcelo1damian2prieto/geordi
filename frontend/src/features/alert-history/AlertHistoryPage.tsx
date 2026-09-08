import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { AlertEpisodeList } from './AlertEpisodeList'
import { AlertEpisodeDetail } from './AlertEpisodeDetail'
import { alertHistorySearchParams, last24Hours, parseAlertHistorySearchParams } from './alertHistorySearchParams'
import { useAlertEpisode, useAlertEpisodes } from './useAlertHistory'
import { historyFailure } from './alertHistoryPresentation'

function fields(params: URLSearchParams) {
  return { from: params.get('from') ?? '', to: params.get('to') ?? '', policyId: params.get('policyId') ?? '', state: params.get('state') ?? '', limit: params.get('limit') ?? '50' }
}
export function AlertHistoryPage() {
  const [params, setParams] = useSearchParams()
  const search = params.toString()
  const parsed = parseAlertHistorySearchParams(params)
  const active = parsed.status === 'valid' ? parsed.query : undefined
  const episodes = useAlertEpisodes(active)
  const detail = useAlertEpisode(active?.episodeId)
  const [draft, setDraft] = useState(() => ({ search, values: fields(params), error: '' }))
  if (draft.search !== search) setDraft({ search, values: fields(params), error: '' })
  const initialRange = useRef<ReturnType<typeof last24Hours> | null>(null)
  const detailHeading = useRef<HTMLHeadingElement>(null)
  const listHeading = useRef<HTMLHeadingElement>(null)
  const initiatingLink = useRef<HTMLAnchorElement | null>(null)
  const focusAction = useRef<string | null>(null)

  useEffect(() => {
    const current = parseAlertHistorySearchParams(params)
    if (current.status !== 'absent') return
    initialRange.current ??= last24Hours(Date.now())
    setParams(alertHistorySearchParams({ ...initialRange.current, ...current.filters }), { replace: true })
  }, [params, setParams])
  useLayoutEffect(() => {
    if (focusAction.current === active?.episodeId && active?.episodeId) {
      detailHeading.current?.focus()
      focusAction.current = null
    } else if (focusAction.current === 'close' && !active?.episodeId) {
      const target = initiatingLink.current
      if (target?.isConnected) target.focus()
      else listHeading.current?.focus()
      focusAction.current = null
    }
  }, [active?.episodeId])
  const error = draft.error || (parsed.status === 'invalid' ? parsed.message : '')
  const inputProps = { 'aria-describedby': error ? 'history-filter-help history-validation' : 'history-filter-help', 'aria-invalid': !!error }
  function change(name: keyof typeof draft.values, value: string) {
    setDraft({ ...draft, values: { ...draft.values, [name]: value }, error: '' })
  }
  return <main className="alert-history">
    <header className="metrics-hero"><h1>Alert History</h1></header>
    <p><Link to="/alert-evaluations">Alert Lifecycle</Link> remains the authoritative current FIRING-state view.</p>
    <p id="history-filter-help">Use absolute UTC Z timestamps with up to nine fractional digits. From is inclusive; To is exclusive. The window must be positive and at most 31 days. Policy ID is an exact match; limit is 1–100.</p>
    <form className="metrics-controls" onSubmit={(event) => {
      event.preventDefault()
      const next = new URLSearchParams({ from: draft.values.from, to: draft.values.to, limit: draft.values.limit })
      if (draft.values.policyId.trim()) next.set('policyId', draft.values.policyId)
      if (draft.values.state) next.set('state', draft.values.state)
      const result = parseAlertHistorySearchParams(next)
      if (result.status !== 'valid') {
        setDraft({ ...draft, error: result.status === 'invalid' ? result.message : 'From and To are required.' })
        return
      }
      setParams(alertHistorySearchParams(result.query))
    }}>
      <label>From (UTC)<input {...inputProps} value={draft.values.from} onChange={(event) => change('from', event.target.value)} /></label>
      <label>To (UTC)<input {...inputProps} value={draft.values.to} onChange={(event) => change('to', event.target.value)} /></label>
      <label>Policy ID<input {...inputProps} value={draft.values.policyId} onChange={(event) => change('policyId', event.target.value)} /></label>
      <label>State<select {...inputProps} value={draft.values.state} onChange={(event) => change('state', event.target.value)}>
        {!['', 'OPEN', 'CLOSED'].includes(draft.values.state) && <option value={draft.values.state}>Invalid state</option>}
        <option value="">All</option><option value="OPEN">OPEN</option><option value="CLOSED">CLOSED</option>
      </select></label>
      <label>Limit<input {...inputProps} inputMode="numeric" value={draft.values.limit} onChange={(event) => change('limit', event.target.value)} /></label>
      <button type="submit">Apply</button>
      <button type="button" onClick={() => setParams(alertHistorySearchParams(last24Hours(Date.now())))}>Reset to last 24 hours</button>
      <button type="button" disabled={!active} onClick={() => { void episodes.refetch(); if (active?.episodeId) void detail.refetch() }}>Refresh</button>
    </form>
    {error && <p role="alert" id="history-validation">{error}</p>}
    <section aria-labelledby="history-list-heading">
      <h2 id="history-list-heading" tabIndex={-1} ref={listHeading}>Episodes opened in this window</h2>
      <p>OPEN includes only episodes opened in this window that remain unresolved in history. Legacy episodes with an unknown start are excluded from this ranged list; a known episode ID bookmark can open their detail.</p>
      {active && <>
        <p role="status">{episodes.isFetching ? (episodes.data ? 'Refreshing episodes…' : 'Loading episodes…') : episodes.data ? `${episodes.data.alertEpisodes.length} episodes returned` : ''}</p>
        {episodes.isError && <div role="alert"><p>{historyFailure(episodes.error)}{episodes.data ? '. Refresh failed; showing cached results.' : ''}</p><button type="button" onClick={() => void episodes.refetch()}>Retry episode list</button></div>}
        {episodes.data && (episodes.data.alertEpisodes.length === 0 ? <p>No episodes opened in this window match these filters</p> : <>
          <AlertEpisodeList episodes={episodes.data.alertEpisodes} query={active} onSelect={(id, link) => { initiatingLink.current = link; focusAction.current = id; if (id === active.episodeId) { detailHeading.current?.focus(); focusAction.current = null } }} />
          {episodes.data.alertEpisodes.length >= active.limit && <p>Showing up to {active.limit} episodes; narrow the filters.</p>}
        </>)}
      </>}
    </section>
    {active?.episodeId && <AlertEpisodeDetail key={active.episodeId} query={detail} headingRef={detailHeading} onClose={() => {
      focusAction.current = 'close'
      const next = { ...active }
      delete next.episodeId
      setParams(alertHistorySearchParams(next))
    }} />}
  </main>
}
