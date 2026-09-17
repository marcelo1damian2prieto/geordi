# ADR-021: Bounded Multiwindow Burn-Rate Conditions and Durable Evidence Compatibility

## Status

Accepted — implemented locally; Milestone 18 remains open pending its full closure process.

## Context

Legacy alert policies evaluate one configured-SLO-window burn rate with
`BURN_RATE_ABOVE`. Operators also need bounded fast/slow burn-rate conditions without
changing the public SLO configuration contract or losing the evidence that produced a
durable lifecycle transition. Existing M17 lifecycle, history, outbox, and delivery
rows contain unversioned JSON and must remain readable.

## Decision

Alerts owns a closed `AlertObservationWindow` set: `PT5M`, `PT30M`, `PT1H`, and
`PT6H`. `PT30M` is not accepted as a configured SLO window or Alerts provenance
window. The SLO application owns a provider-neutral bounded multiwindow evaluation
capability; the Alerts SLO adapter translates between the two boundaries. The SLO
module does not depend on Alerts.

Policies retain legacy `BURN_RATE_ABOVE` and may use closed
`MULTIWINDOW_BURN_RATE` conditions with one or two canonical bands only:
`PT1H`/`PT5M` and `PT6H`/`PT30M`. Each band uses one inclusive threshold for both
observations. Within a band, available false is decisive; otherwise two true values
are met and remaining combinations are unavailable. Across bands, any met band is
met, all not-met bands are not met, and the remainder is unavailable with
`MULTIWINDOW_EVIDENCE_UNAVAILABLE`.

Multiwindow evaluation retains all requested observations under one captured
`evaluatedAt`; each has its exact half-open range and either a finite non-negative burn
value or a bounded reason. Conditions, bands, observations, and derived band results
are canonical and validateable from durable evidence. No representative burn value is
selected.

The persistence adapter owns an explicit JSON codec. Existing unversioned values are
decoded as frozen v1. Multiwindow lifecycle and transition values use a v2 envelope and
are decoded only after reconstructing and validating the closed domain model, including
derived band results. Reads do not rewrite v1 rows. Unknown or inconsistent durable
data fails closed. Transition, episode, and delivery identity formulas remain unchanged.

Webhook schema comes exclusively from the decoded persisted transition: legacy values
emit `geordi.notification.v1`; multiwindow values emit
`geordi.notification.v2`. Current policy configuration is never consulted for this
choice. Existing delivery binding, delivery ID, idempotency key, retry, and restart
semantics are unchanged.

## Rollout and rollback

Before the first v2 durable write, a normal binary rollback to an M17 reader remains
possible, subject to ordinary deployment compatibility. After that first write, an M17
binary is not a supported reader. Supported recovery requires an M18-compatible reader
or a coordinated restore of pre-upgrade storage and matching policy configuration.
Restoring storage discards later lifecycle, history, acknowledgement, disposition, and
delivery facts; it is not an automatic downgrade. Geordi neither rewrites v2 values to
v1 nor deletes them as rollback behavior.

## Consequences

The public configured-SLO contract remains stable, while multiwindow evidence is
bounded to two bands and four observations. Legacy firing lifecycles retain their
legacy condition and can freeze/recover under their original semantics after upgrade.
M18 adds no SQL migration, history backfill, arbitrary boolean rules, additional
observation windows, policy reload, or multi-node scheduler ownership.
