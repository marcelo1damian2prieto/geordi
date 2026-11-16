# ExecPlan: M12 overlap Collector lifecycle and propagation isolation

## Status

Focused offline/config-only implementation and validation passed; awaiting independent read-only review. Backend overlap generations, M13, CI activation, runtime execution, and Gate 5 remain out of scope. Candidate remains DIAGNOSTIC ONLY; M19 remains NOT READY.

## Goal

Add an explicit generation-aware Collector mode to the M12 overlap harness while preserving the current standalone default. Replace both same-ID/raw Collector lifecycle operations with two sequential uses of the accepted M12 Collector handoff helper, and isolate only Compose restart propagation needed by overlap mutations.

## Constraints

- Do not change shared generation/Collector helpers, backend lifecycle integration, CI, M13, TLS, captures, runtime, or protected volumes.
- The overlap-only Compose overlay may change only `depends_on.*.restart`; all service/dependency configuration must otherwise remain structurally equal.
- The mode is opt-in and is not activated in `.gitlab-ci.yml`.
- Keep all validation synthetic or config-only; run no Docker lifecycle command.

## Implementation and validation

1. Map current overlap Collector boundaries and exact Compose file set.
2. Add a narrow overlap isolation overlay and config-equivalence/propagation negative tests.
3. Add an explicit Collector-generation mode that adapts the accepted helper's exact service-scoped replacement command to the overlap file set without modifying the shared helper.
4. Preserve standalone overlap behavior and all overlap assertions; separate service starts only as required to keep VM, Collector, and backend replacement scopes explicit.
5. Prove two sequential Collector handoffs, sealed-history immutability, failure behavior, accepted M12 Collector regression, manifest integrity, and protected-volume configuration.
6. Run focused parser, config, synthetic, and diff checks fail-fast; then obtain a fresh independent read-only review.

### Actual validation

- `scripts/Test-GeordiM12OverlapCollector.ps1 -SelfTest`: PASS. Normal render had 7 effective restart edges; isolated render had 0. Normalized config equivalence, 8 negative mutations, service-scoped `--no-deps --force-recreate otel-collector`, protected-volume config identity, two sequential synthetic handoffs, follower-before-readiness, and historical capture immutability passed.
- `scripts/Test-GeordiM12CollectorReplacement.ps1 -SelfTest`: PASS.
- `scripts/Test-GeordiCaptureGenerations.ps1 -Case Manifest`: PASS.
- PowerShell parser for overlap module, overlap self-test, and overlap runner: PASS.
- `git diff --check`: PASS; Git emitted only pre-existing line-ending normalization warnings.
- No Docker lifecycle, TLS, capture, cleanup, CI, Gate 5, or runtime operation was performed.

## Stop conditions

Stop before extending shared helpers if sequential replacements fail; stop if the M12 helper cannot be safely adapted to the exact overlap command/file set; stop if preserving the accepted Collector behavior requires backend semantic changes. Do not implement backend generations or activate CI in this plan.
