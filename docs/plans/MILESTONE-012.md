# Milestone 012 — Automated Alert Evaluation Scheduling Foundation

Status: MILESTONE 12 READY FOR GITLAB REVALIDATION

## Build-contract implementation

The current GitLab `backend` job runs the authoritative `./mvnw verify`, but
`local_stack_smoke` subsequently runs `docker compose build --no-cache`; the current
backend Dockerfile runs `verify` again before exporting the runtime image. This
duplicates the tests, ArchUnit, PMD, SpotBugs, and Find Security Bugs, and prevents
runtime image export in the bounded local execution environment.

The implemented CI-specific Docker target is selected explicitly
by `local_stack_smoke` through a Compose build argument, not a new default
developer workflow. The existing default Docker target remains source-based and runs
its full safe build for `docker compose build backend` and `docker compose up --build`.
The CI runtime target accepts an explicitly supplied, verified JAR plus a provenance
file from the direct `backend` job dependency. The backend job will publish only its
post-`verify` JAR and a metadata file containing `CI_COMMIT_SHA` and the JAR SHA-256,
alongside the existing reports and JUnit artifacts.
`local_stack_smoke` will request that same job's artifacts (`needs: artifacts: true`),
verify metadata, SHA, and expected commit before Docker build, then pass the artifact
directory and revision as explicit build arguments. The target fails closed if any
file, checksum, or revision is absent or mismatched. Inside that CI target, before
copying the application JAR, a build-stage command computes the digest of the exact
file to be copied and compares it to the required SHA argument; an OCI label alone
is never treated as proof of copied bytes.

The CI image target adds `org.opencontainers.image.revision=$CI_COMMIT_SHA` and the
artifact SHA as OCI labels. The smoke job inspects both labels before starting the
stack. Its Docker build uses `--no-cache`, and the verified artifact path is the only
application input copied into the CI target, so an older cached JAR cannot appear
current. This is JAR provenance, not a claim of complete image reproducibility; the
independently checksum-pinned Java-agent stage remains unchanged.

Alternatives rejected: a plain `COPY target/*.jar` has no freshness guarantee;
a separate CI Dockerfile duplicates runtime instructions and risks drift; retaining
the default Dockerfile for CI preserves safety but unnecessarily repeats quality
analysis. Rollback is to use the default source-verifying Docker target. This design
does not change product behavior or Maven quality gates, and does not claim artifact
provenance outside the direct same-pipeline GitLab dependency.

## Objective and product value

M12 makes the existing configured alert policies operational without an operator
calling the lifecycle endpoint for every evaluation. It adds a bounded,
deployment-managed trigger that invokes the canonical M10 lifecycle use case. M9
continues to own current burn-rate evaluation, M10 owns lifecycle decisions and
durable state, and M11 owns transactional notification outbox creation and delivery.

## Evidence and current baseline

M9 provides the read-only `AlertEvaluationUseCase`; M10's
`AlertLifecycleEvaluationUseCase` invokes it exactly once and atomically commits a
transition plus any M11 outbox work. M11's `NotificationDeliveryWorker` already
uses Spring scheduling only as an adapter for bounded outbox polling. Policies are
a startup-validated, read-only catalog (maximum 50) and have an `enabled` flag.
The existing GitLab sequence runs M9, M10, and M11 explicit smokes in order. Its
base Compose configuration must not acquire automatic lifecycle mutation.

## Architecture decision

Keep M12 inside the existing `alerts` bounded context as an inbound worker adapter:
`alerts.adapter.in.worker.AlertEvaluationScheduler`. It receives only
`AlertPolicyCatalog` and the canonical `AlertLifecycleEvaluationUseCase`. It does
not depend on controllers, SLO implementations, provider adapters, JDBC/H2,
notification sender/work repositories, or the frontend. Spring composition creates
the bounded scheduling infrastructure. No new bounded context, persistence model,
scheduler framework, API, or UI is justified.

## Configuration and scheduling semantics

Use the separate deployment-managed `geordi.scheduling.alert` configuration rather
than extending policy semantics. It has `enabled` (default `false`), a global
interval validated to 10 seconds through 15 minutes, worker count validated to 1–4,
queue capacity validated to 0–50, and a shutdown grace period validated to 1–30
seconds (default 5 seconds). This retains backward compatibility with existing YAML
policies and makes old semantic smokes deterministic. The M12 Compose/smoke path
enables it explicitly.

On startup, the scheduler reconstructs work from the immutable catalog. Enabled
policies receive deterministic initial offsets from their catalog position within
the global interval, then fixed-rate triggers. Disabled policies are never
scheduled. The smallest permitted interval prevents accidental provider load; the
catalog bound and deterministic spreading avoid a startup herd. Restart loses no
lifecycle or delivery state because M10/M11 already persist it, but M12 does not
replay missed ticks or persist schedule state.

All lifecycle entry points share an application-level, per-policy single-flight
coordinator immediately around the canonical lifecycle use case. The scheduler uses
its non-blocking acquisition: if a manual request or prior scheduled invocation is
running, it records an overlap skip. A concurrent manual request receives a bounded
controlled `evaluation in progress` conflict rather than creating a second provider
evaluation; the existing manual endpoint remains otherwise unchanged. The coordinator
does not derive evaluations or transitions.

After acquiring its lease, a due tick submits one invocation to a bounded executor.
A rejected submission records bounded backpressure evidence and releases the lease;
it does not create retry work. Successful submission invokes only
`AlertLifecycleEvaluationUseCase.evaluate(policyId)`. Exceptions are logged without
policy/secret detail and recorded, then contained so another policy remains eligible
on later ticks. `UNAVAILABLE` remains the ordinary canonical M9/M10 result: M12
does not convert it to a transition, retry it, or create notification work.

Shutdown cancels future schedules before stopping the executor. The validated
`geordi.scheduling.alert.shutdown-grace-period` property has a finite default and
an explicit upper bound; it determines how long active canonical operations may
complete before remaining work is interrupted. No new work is accepted during shutdown.

## Time, health, observability, and security

The scheduler does not create M9/M10 evidence timestamps; those remain canonical
lifecycle data. It records bounded process duration with a monotonic clock. Tests use
bounded synchronization and do not use long sleeps as semantic correctness proof.

Scheduler metrics are low-cardinality only: attempts, completed outcomes, failures,
overlap skips, capacity rejections, and duration. They carry no policy/SLO identifiers,
identity, exception text, or secrets. A policy/provider evaluation failure does not make the
scheduler or platform health down. Existing persistence health remains authoritative;
an infrastructure-level inability to initialize scheduling is a startup failure.
No new secrets, endpoint, API, or frontend surface is introduced.

## Tests and architecture enforcement

Add unit tests for enabled/disabled dispatch, canonical invocation, manual/scheduled
same-policy single-flight, bounded rejection, failure isolation, deterministic startup
offsets, shutdown, and low-cardinality telemetry. Initial offsets use the catalog's
stable sorted order: for `n` enabled policies, policy index `i` starts at
`floor(interval * i / n)`; this has no hash collisions and bounds the largest cohort
to one policy for the catalog's maximum 50 entries. Extend integration tests to prove
scheduler composition and that explicit lifecycle evaluation still works. Extend ArchUnit so
scheduling dependencies are confined to inbound worker/Spring composition and the
scheduler cannot depend on providers, persistence, webhook delivery, or web APIs.

## Semantic smoke and CI integration

`scripts/verify-alert-scheduling.ps1` starts from deterministic local
infrastructure and uses dedicated, never-before-used M12 policy ids so the preceding
M9–M11 smokes cannot contaminate first-start assertions. It enables scheduling only
for M12 by intentionally recreating the backend with
`GEORDI_SCHEDULING_ALERT_ENABLED=true`, then polls bounded deadlines and proves
automatic start, no duplicate start, automatic resolution, disabled suppression,
provider-unavailable freeze/recovery, bounded telemetry, restart reconstruction,
and durable M10/M11 state/outbox behavior. Append it after M11 in the checked-in
GitLab `local_stack_smoke` sequence. Earlier smokes remain deterministic because
scheduling defaults to disabled in base Compose.

## Acceptance criteria

- An enabled policy is automatically processed through the unchanged M9→M10→M11 chain.
- Disabled policies receive no scheduled work.
- Same-policy work never overlaps; capacity is bounded and observable.
- A failure or unavailability is isolated and never fabricates alert transitions or delivery work.
- Startup, restart, shutdown, health, timestamps, and single-node limitations are explicit and tested.
- No scheduler persistence, runtime CRUD, arbitrary cron, frontend/API, or distributed coordination is added.
- M1–M11 smokes retain deterministic explicit behavior; M12 smoke is appended after M11.

## Rollback, limitations, and technical debt

Set `geordi.scheduling.alert.enabled=false` and redeploy to stop future automatic
evaluation; existing M10 state and M11 delivery work remain intact. M12 is
single-node and provides neither leader election nor missed-tick replay, exactly-once
scheduling, historical backfill, policy reload, or per-policy cadence. Multi-node
scheduler ownership and policy-specific cadence are deferred until deployment/product
evidence justifies them.

## Documentation updates

After verified implementation, update the alert architecture/module and
self-observability documentation, deployment instructions, roadmap/product status,
README, technical debt, and GitLab/Compose documentation only to match delivered
behavior. M12 remains `READY FOR GITLAB REVALIDATION` locally until authoritative CI
is confirmed.
