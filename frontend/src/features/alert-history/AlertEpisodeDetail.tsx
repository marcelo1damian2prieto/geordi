import { useState, type RefObject } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import type { UseQueryResult } from '@tanstack/react-query'
import type { AlertEpisodeDetailResponse } from '../../api/alertHistory'
import { acknowledgeAlertEpisode } from '../../api/alertHistory'
import { currentAuthenticationGeneration, isAuthenticationGenerationCurrent } from '../../api/client'
import { isMultiwindowAlertEvaluation } from '../../api/alertEvaluations'
import { ApiError } from '../../api/client'
import { hasAtMostCodePoints, stripJavaWhitespace } from './acknowledgementInput'
import { episodeDuration, episodeStatus, historyFailure, notificationDeliveryLabel, notificationDispositionLabel, notificationTimestamps, transitionLabel } from './alertHistoryPresentation'
import { alertStatusLabel, alertUnavailableReason } from '../alert-evaluations/alertEvaluationPresentation'
import { AlertConditionDetails, AlertEvidenceDetails } from '../alert-evaluations/AlertEvidenceDetails'
import { useGeordiPermissions } from '../auth/AuthContext'

export function AlertEpisodeDetail({ query, headingRef, onClose }: {
  query: UseQueryResult<AlertEpisodeDetailResponse, Error>; headingRef: RefObject<HTMLHeadingElement | null>; onClose: () => void
}) {
  const episode = query.data?.episode
  const permissions = useGeordiPermissions()
  const queryClient = useQueryClient()
  const [reason, setReason] = useState('')
  const normalizedReason = stripJavaWhitespace(reason)
  const mutation = useMutation({
    mutationFn: () => acknowledgeAlertEpisode(episode!.id, {
      reason: normalizedReason || null,
    }),
    onMutate: () => currentAuthenticationGeneration(),
    onSuccess: (_result, _variables, generation) => {
      if (generation !== undefined && isAuthenticationGenerationCurrent(generation)) {
        void queryClient.invalidateQueries({ queryKey: ['alert-history', 'episode', episode?.id] })
      }
    },
    onError: (_error, _variables, generation) => {
      if (generation !== undefined && isAuthenticationGenerationCurrent(generation)) {
        void queryClient.invalidateQueries({ queryKey: ['alert-history', 'episode', episode?.id] })
      }
    },
  })
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
      {episode.closedAt === null && !query.data?.acknowledgement && permissions.has('alerts:acknowledge') && <form onSubmit={(event) => { event.preventDefault(); mutation.mutate() }}>
        <h3>Acknowledgement</h3>
        <p>Your authenticated identity will be recorded with this acknowledgement.</p>
        <label htmlFor="ack-reason">Reason (optional)</label>
        <textarea id="ack-reason" value={reason} onChange={(event) => {
          if (hasAtMostCodePoints(stripJavaWhitespace(event.target.value), 512)) setReason(event.target.value)
        }} />
        <button type="submit" disabled={mutation.isPending}>Acknowledge</button>
        {mutation.isError && <p role="alert">{mutation.error instanceof ApiError && mutation.error.status === 409 ? 'The episode changed; refreshed detail is shown.' : 'Acknowledgement failed. Retry.'}</p>}
      </form>}
      {query.data?.acknowledgement && <section aria-label="Acknowledgement"><h3>Acknowledged</h3><p>Actor: {query.data.acknowledgement.actor}</p><p>Attribution: {query.data.acknowledgement.attribution.provenance === 'AUTHENTICATED_PRINCIPAL' ? 'Authenticated principal' : 'Legacy caller asserted'}</p><p>Reason: {query.data.acknowledgement.reason ?? 'No reason provided'}</p><time dateTime={query.data.acknowledgement.acknowledgedAt}>{query.data.acknowledgement.acknowledgedAt}</time></section>}
      <h3>Transitions — newest first</h3>
      {query.data?.transitions.map((transition) => {
        const evaluation = transition.evaluation
        const evidence = evaluation.evidence
        const delivery = transition.notification.delivery
        const timestamps = delivery === null ? null : notificationTimestamps(delivery)
        return <article key={transition.id}>
          <h4>{transitionLabel(transition.type)}</h4>
          <p>{transition.previousState} → {transition.currentState} at <time dateTime={transition.occurredAt}>{transition.occurredAt}</time></p>
          <dl className="alert-evaluation-facts">
            <div><dt>Historical policy</dt><dd>{evaluation.policyName}</dd></div>
            <div><dt>SLO</dt><dd>{evaluation.sloId}</dd></div>
            <div><dt>Condition</dt><dd><AlertConditionDetails condition={evaluation.condition} /></dd></div>
            <div><dt>Evaluation status</dt><dd>{alertStatusLabel(evaluation.status)}</dd></div>
            <div><dt>Aggregate result</dt><dd>{alertStatusLabel(evaluation.status)}</dd></div>
          </dl>
          {evaluation.status === 'UNAVAILABLE' && <p>{alertUnavailableReason(evaluation.reason)}</p>}
          {evidence && <AlertEvidenceDetails
            evidence={evidence}
            bandResults={isMultiwindowAlertEvaluation(evaluation) ? evaluation.bandResults : undefined}
            headingId={`transition-${transition.id}-evidence`}
            heading="Persisted evaluation evidence"
            headingLevel={5}
            investigationLabel={(windowLabel) => evaluation.condition.type === 'MULTIWINDOW_BURN_RATE'
              ? `Investigate ${transitionLabel(transition.type)} ${windowLabel} observation for transition ${transition.id}`
              : `Investigate ${transitionLabel(transition.type)} evidence`}
          />}
          <section aria-label="Notification">
            <h5>Notification</h5>
            <dl className="alert-evaluation-facts">
              <div><dt>Disposition</dt><dd>{notificationDispositionLabel(transition.notification.disposition)}</dd></div>
              {delivery && <>
                <div><dt>Delivery</dt><dd>{notificationDeliveryLabel(delivery)}</dd></div>
                <div><dt>Claims consumed</dt><dd>{delivery.attempts}</dd></div>
                <div><dt>Created (UTC)</dt><dd><time dateTime={timestamps!.createdAt}>{timestamps!.createdAt}</time></dd></div>
                {timestamps!.nextAttemptAt !== null && <div><dt>Next attempt (UTC)</dt><dd><time dateTime={timestamps!.nextAttemptAt}>{timestamps!.nextAttemptAt}</time></dd></div>}
                {timestamps!.completedAt !== null && <div><dt>Completed (UTC)</dt><dd><time dateTime={timestamps!.completedAt}>{timestamps!.completedAt}</time></dd></div>}
              </>}
            </dl>
          </section>
        </article>
      })}
    </>}
  </section>
}
