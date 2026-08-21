# ADR-016: Current-Window Error Budget and Burn Rate

Status: ACCEPTED

## Context

Milestone 7 evaluates `AVAILABILITY` and `ERROR_RATE` objectives from one canonical
whole-window request/error measurement. Milestone 8 must explain current error-budget
consumption without duplicating SLI direction rules, issuing mismatched provider
queries, inventing long-period accounting, or exposing non-finite numeric values.

A separate burn endpoint called alongside the existing evaluation endpoint would
capture a second time and perform a second provider query. The UI could then combine
objective status and burn evidence from different ranges. A separate module or store
would also create ownership and lifecycle that derived current-window evidence does not
require.

## Decision

Error-budget and burn-rate behavior remains in the existing `slos` bounded context.
The on-demand SLO evaluation is enriched with a nested burn evaluation derived from the
same definition, canonical measurement, service identity, and exact half-open range.
There is no new persistence or background evaluator.

One pure domain policy owns SLI interpretation:

- `AVAILABILITY`: observed SLI `(N-E)/N`, allowed bad ratio `1-target`;
- `ERROR_RATE`: observed SLI `E/N`, allowed bad ratio `target`;
- both current request-based SLIs: observed bad ratio `E/N`.

For a positive allowed bad ratio, burn rate is calculated directly as
`E / (N * allowedBadRatio)`. Calculations use `BigDecimal`; returned derived values use
12 significant decimal digits with half-up rounding, while objective comparison
retains exact cross-multiplication and never depends on presentation rounding. A
positive derived ratio cannot be rounded to canonical zero.

The public numeric contract is an IEEE-754 finite `double`. Nonzero targets, allowed
ratios, observed ratios, and burn rates must remain finite and nonzero when represented
by that contract. Catalog definitions whose positive allowed ratio could produce a
burn rate above the contract are rejected. If provider evidence would produce a
positive ratio below the contract, evaluation is `UNAVAILABLE/INVALID_TELEMETRY`
instead of fabricating zero. API values remain ratios and the frontend alone formats
percentages; it also treats any out-of-contract numeric payload as unavailable.

Burn status is exactly `AVAILABLE` or `UNAVAILABLE`. Existing evidence failures reuse
the bounded M7 unavailable reason. When the allowed bad ratio is zero, the parent SLO
evaluation remains valid when its telemetry is valid, the observed bad ratio remains
available, but burn rate is null with `UNAVAILABLE/ZERO_ALLOWED_BAD_RATIO`. Neither
`NaN` nor infinity represents a domain or public API value.

Only the definition's configured evaluation window is used. Milestone 8 does not add
fast/slow pairs, alert classifications, thresholds, or remaining-budget accounting.

## Consequences

- Objective and burn evidence cannot drift across identity or time within one response.
- SLI directionality has one canonical owner and remains provider-neutral.
- Existing canonical Metrics and VictoriaMetrics adapter boundaries are reused without
  a burn-specific query port or provider expression.
- Perfect targets remain valid definitions without leaking division-by-zero artifacts.
- The existing bounded per-definition frontend fan-out does not double.
- A future alerting context may consume this provider-neutral evidence, but no alerting
  policy, state machine, scheduler, storage, or notification contract is introduced now.
