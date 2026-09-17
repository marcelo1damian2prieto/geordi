import { Link } from 'react-router-dom'
import type { ReactNode } from 'react'
import type {
  AlertCondition,
  AlertEvidence,
  BurnRateBandResult,
  MultiwindowAlertEvidence,
  WindowBurnRateObservation,
} from '../../api/alertEvaluations'
import { serviceLabel } from '../../api/telemetryContext'
import {
  alertBandLabel,
  alertBandOutcomeLabel,
  alertConditionSummary,
  alertWindowLabel,
  exactInvestigationTarget,
  formatAlertBurnRate,
  isLegacyAlertEvidence,
  observationBurnRateLabel,
} from './alertEvaluationPresentation'

export function AlertConditionDetails({ condition }: { condition: AlertCondition }) {
  if (condition.type === 'BURN_RATE_ABOVE') return <>{alertConditionSummary(condition)}</>
  return (
    <div>
      <span>{alertConditionSummary(condition)}</span>
      <ol className="alert-band-definitions" aria-label="Configured burn-rate bands">
        {condition.bands.map((band) => (
          <li key={`${band.longWindow}-${band.shortWindow}`}>
            {alertBandLabel(band)} at {formatAlertBurnRate(band.threshold)}
          </li>
        ))}
      </ol>
    </div>
  )
}

function EvidenceHeading({ level, id, className, children }: {
  level: number
  id: string
  className?: string
  children: ReactNode
}) {
  if (level <= 3) return <h3 id={id} className={className}>{children}</h3>
  if (level === 4) return <h4 id={id} className={className}>{children}</h4>
  if (level === 5) return <h5 id={id} className={className}>{children}</h5>
  return <h6 id={id} className={className}>{children}</h6>
}

function ObservationDetails({
  observation,
  service,
  headingId,
  role,
  investigationLabel,
  headingLevel,
}: {
  observation: WindowBurnRateObservation
  service: MultiwindowAlertEvidence['service']
  headingId: string
  role: 'Long' | 'Short' | 'Observation'
  investigationLabel: (windowLabel: string) => string
  headingLevel: number
}) {
  const windowLabel = alertWindowLabel(observation.observationWindow)
  const target = exactInvestigationTarget(service, observation.range)
  return (
    <article className="alert-observation" aria-labelledby={headingId}>
      <EvidenceHeading level={headingLevel} id={headingId} className="alert-observation-heading">
        {role} — {windowLabel}
      </EvidenceHeading>
      <dl className="alert-evaluation-facts alert-observation-facts">
        <div><dt>Observed burn rate</dt><dd>{observationBurnRateLabel(observation)}</dd></div>
        <div><dt>From (inclusive)</dt><dd><time dateTime={observation.range.from}>{observation.range.from}</time></dd></div>
        <div><dt>To (exclusive)</dt><dd><time dateTime={observation.range.to}>{observation.range.to}</time></dd></div>
      </dl>
      {target
        ? <Link className="view-traces-link" to={target} aria-label={investigationLabel(windowLabel)}>Investigate {windowLabel} observation</Link>
        : <p>Investigation unavailable for this persisted observation</p>}
    </article>
  )
}

function BurnBandDetails({
  result,
  evidence,
  headingId,
  investigationLabel,
  headingLevel,
}: {
  result: BurnRateBandResult
  evidence: MultiwindowAlertEvidence
  headingId: string
  investigationLabel: (windowLabel: string) => string
  headingLevel: number
}) {
  return (
    <li className="alert-burn-band">
      <section aria-labelledby={headingId}>
        <EvidenceHeading level={headingLevel} id={headingId} className="alert-burn-band-heading">
          Burn band — {alertBandLabel(result.band)}
        </EvidenceHeading>
        <dl className="alert-evaluation-facts">
          <div><dt>Threshold</dt><dd>{formatAlertBurnRate(result.band.threshold)}</dd></div>
          <div><dt>Band result</dt><dd>{alertBandOutcomeLabel(result.outcome)}</dd></div>
        </dl>
        <div className="alert-band-observations">
          <ObservationDetails
            observation={result.longObservation}
            service={evidence.service}
            headingId={`${headingId}-long`}
            role="Long"
            investigationLabel={investigationLabel}
            headingLevel={headingLevel + 1}
          />
          <ObservationDetails
            observation={result.shortObservation}
            service={evidence.service}
            headingId={`${headingId}-short`}
            role="Short"
            investigationLabel={investigationLabel}
            headingLevel={headingLevel + 1}
          />
        </div>
      </section>
    </li>
  )
}

export function AlertEvidenceDetails({
  evidence,
  bandResults,
  headingId,
  heading = 'Canonical evaluation evidence',
  investigationLabel,
  headingLevel = 3,
}: {
  evidence: AlertEvidence
  bandResults?: BurnRateBandResult[]
  headingId: string
  heading?: string
  investigationLabel: (windowLabel: string) => string
  headingLevel?: 3 | 4 | 5
}) {
  if (isLegacyAlertEvidence(evidence)) {
    const target = exactInvestigationTarget(evidence.service, evidence.range)
    return (
      <section className="alert-evidence" aria-labelledby={headingId}>
        <EvidenceHeading level={headingLevel} id={headingId}>{heading}</EvidenceHeading>
        <dl className="alert-evaluation-facts">
          <div><dt>Service</dt><dd>{serviceLabel(evidence.service)}</dd></div>
          <div><dt>Configured SLO provenance window</dt><dd>{alertWindowLabel(evidence.window)}</dd></div>
          <div><dt>Evaluated</dt><dd><time dateTime={evidence.evaluatedAt}>{new Date(evidence.evaluatedAt).toLocaleString()}</time></dd></div>
          <div><dt>Observed burn rate</dt><dd>{evidence.observedBurnRate === null ? 'Unavailable' : formatAlertBurnRate(evidence.observedBurnRate)}</dd></div>
        </dl>
        <p className="alert-evaluation-explanation">Exact half-open interval [from, to)</p>
        <dl className="alert-evaluation-facts alert-evaluation-window-facts">
          <div><dt>From (inclusive)</dt><dd><time dateTime={evidence.range.from}>{evidence.range.from}</time></dd></div>
          <div><dt>To (exclusive)</dt><dd><time dateTime={evidence.range.to}>{evidence.range.to}</time></dd></div>
        </dl>
        {target
          ? <Link className="view-traces-link" to={target} aria-label={investigationLabel(alertWindowLabel(evidence.window))}>Investigate service</Link>
          : <p>Investigation unavailable for this persisted evidence</p>}
      </section>
    )
  }

  return (
    <section className="alert-evidence" aria-labelledby={headingId}>
      <EvidenceHeading level={headingLevel} id={headingId}>{heading}</EvidenceHeading>
      <dl className="alert-evaluation-facts">
        <div><dt>Service</dt><dd>{serviceLabel(evidence.service)}</dd></div>
        <div><dt>Configured SLO provenance window</dt><dd>{alertWindowLabel(evidence.configuredSloWindow)}</dd></div>
        <div><dt>Evaluated</dt><dd><time dateTime={evidence.evaluatedAt}>{new Date(evidence.evaluatedAt).toLocaleString()}</time></dd></div>
      </dl>
      {bandResults && bandResults.length > 0
        ? (
          <ol className="alert-burn-bands" aria-label="Evaluated burn-rate bands">
            {bandResults.map((result) => (
              <BurnBandDetails
                key={`${result.band.longWindow}-${result.band.shortWindow}`}
                result={result}
                evidence={evidence}
                headingId={`${headingId}-${result.band.longWindow.toLowerCase()}`}
                investigationLabel={investigationLabel}
                headingLevel={headingLevel + 1}
              />
            ))}
          </ol>
        )
        : (
          <div className="alert-band-observations" aria-label="Persisted burn-rate observations">
            {evidence.observations.map((observation) => (
              <ObservationDetails
                key={observation.observationWindow}
                observation={observation}
                service={evidence.service}
                headingId={`${headingId}-${observation.observationWindow.toLowerCase()}`}
                role="Observation"
                investigationLabel={investigationLabel}
                headingLevel={headingLevel + 1}
              />
            ))}
          </div>
        )}
    </section>
  )
}
