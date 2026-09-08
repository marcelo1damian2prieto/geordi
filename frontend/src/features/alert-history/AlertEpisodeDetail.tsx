import type { RefObject } from 'react'
import { Link } from 'react-router-dom'
import type { UseQueryResult } from '@tanstack/react-query'
import type { AlertEpisodeDetailResponse } from '../../api/alertHistory'
import { episodeDuration, episodeStatus, historyFailure, investigationTarget, transitionLabel } from './alertHistoryPresentation'
import { alertConditionLabel, alertStatusLabel, alertWindowLabel, formatAlertBurnRate } from '../alert-evaluations/alertEvaluationPresentation'

export function AlertEpisodeDetail({ query, headingRef, onClose }: {
  query: UseQueryResult<AlertEpisodeDetailResponse, Error>; headingRef: RefObject<HTMLHeadingElement | null>; onClose: () => void
}) {
  const episode = query.data?.episode
  return <section aria-labelledby="history-detail-heading" className="state-panel">
    <h2 id="history-detail-heading" tabIndex={-1} ref={headingRef}>Episode detail</h2>
    <button type="button" onClick={onClose}>Close episode detail</button>
    <p>Selected episode detail is independent of these list filters.</p>
    <p>Alert history can outlive source telemetry retention. Metrics, traces, or logs for this evidence window may no longer be available.</p>
    <p role="status">{query.isFetching ? (episode ? 'Refreshing episode detail…' : 'Loading episode detail…') : episode ? 'Episode detail loaded' : ''}</p>
    {query.isError && <div role="alert"><p>{historyFailure(query.error, true)}{episode ? '. Refresh failed; showing cached episode detail.' : ''}</p><button type="button" onClick={() => void query.refetch()}>Retry episode detail</button></div>}
    {episode && <>
      <dl className="alert-evaluation-facts">
        <div><dt>Episode ID</dt><dd>{episode.id}</dd></div><div><dt>Policy ID</dt><dd>{episode.policyId}</dd></div>
        <div><dt>Status</dt><dd>{episodeStatus(episode)}</dd></div><div><dt>Origin</dt><dd>{episode.origin}</dd></div>
        <div><dt>Opened (UTC)</dt><dd>{episode.openedAt === null ? 'Start unavailable' : <time dateTime={episode.openedAt}>{episode.openedAt}</time>}</dd></div>
        <div><dt>Resolved (UTC)</dt><dd>{episode.closedAt === null ? 'Not resolved' : <time dateTime={episode.closedAt}>{episode.closedAt}</time>}</dd></div>
        <div><dt>Duration</dt><dd>{episodeDuration(episode)}</dd></div>
      </dl>
      <h3>Transitions — newest first</h3>
      {query.data?.transitions.map((transition) => {
        const evaluation = transition.evaluation
        const evidence = evaluation.evidence
        const target = investigationTarget(evidence)
        return <article key={transition.id}>
          <h4>{transitionLabel(transition.type)}</h4>
          <p>{transition.previousState} → {transition.currentState} at <time dateTime={transition.occurredAt}>{transition.occurredAt}</time></p>
          <dl className="alert-evaluation-facts">
            <div><dt>Historical policy</dt><dd>{evaluation.policyName}</dd></div>
            <div><dt>SLO</dt><dd>{evaluation.sloId}</dd></div>
            <div><dt>Condition</dt><dd>{alertConditionLabel(evaluation.condition.type)} {formatAlertBurnRate(evaluation.condition.threshold)}</dd></div>
            <div><dt>Evaluation status</dt><dd>{alertStatusLabel(evaluation.status)}</dd></div>
            {evidence && <>
              <div><dt>Service</dt><dd>{evidence.service.name}</dd></div><div><dt>Namespace</dt><dd>{evidence.service.namespace ?? 'No namespace'}</dd></div><div><dt>Environment</dt><dd>{evidence.service.environment}</dd></div>
              <div><dt>Evidence window</dt><dd>{alertWindowLabel(evidence.window)}</dd></div>
              <div><dt>Evidence from (UTC)</dt><dd><time dateTime={evidence.range.from}>{evidence.range.from}</time></dd></div>
              <div><dt>Evidence to (UTC)</dt><dd><time dateTime={evidence.range.to}>{evidence.range.to}</time></dd></div>
              <div><dt>Evaluated at (UTC)</dt><dd><time dateTime={evidence.evaluatedAt}>{evidence.evaluatedAt}</time></dd></div>
              <div><dt>Observed burn rate</dt><dd>{evidence.observedBurnRate === null ? 'Unavailable' : formatAlertBurnRate(evidence.observedBurnRate)}</dd></div>
            </>}
          </dl>
          {target ? <Link to={target}>Investigate {transitionLabel(transition.type)} evidence</Link> : <p>Investigation unavailable for this persisted evidence</p>}
        </article>
      })}
    </>}
  </section>
}
