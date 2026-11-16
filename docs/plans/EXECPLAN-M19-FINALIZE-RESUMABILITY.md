# ExecPlan: M19 Finalize Attempt Isolation and Recovery

## Objective

Make the M19 credential-evidence `Finalize` operation fail-closed, resumable, and
idempotent while preserving every partial evidence artifact. Each invocation must
write to a unique attempt directory, publish manifest state atomically, and allow
at most one immutable completed attempt.

## Scope

- `scripts/New-GeordiCredentialEvidence.ps1` and narrowly scoped private-evidence
  helpers.
- M19 cleanup discovery/removal for attempt-scoped evidence.
- Focused PowerShell self-tests for attempt allocation, manifest publication,
  completion guards, source/channel identity, and cleanup.
- `docs/plans/MILESTONE-019.md` status/evidence notes after validation.

No application code, telemetry semantics, deployment configuration, TLS bootstrap,
or existing runtime evidence is to be changed.

## Constraints

- Preserve the live diagnostic-only candidate `f0fb022ba2ab4b7a81f366b4e0e0c4d4`,
  its runtime, capture root, and both protected M19 volumes during focused work.
- Do not rerun Finalize in its current form, TLS bootstrap, unrelated gates, full
  regression, cleanup, commit, push, pipeline, or M20.
- Never overwrite prior attempt files. A retry gets a new attempt ID and isolated
  paths; incomplete attempts remain immutable and discoverable by cleanup.
- Only an atomic manifest publication after all phases may set completion. A
  completed manifest rejects Finalize before any side effect.
- Cleanup removes the recovery pointer only after validating and removing all
  in-scope attempt artifacts, and never removes protected volumes.

## Plan

1. Audit the current manifest schema, Finalize write sites, cleanup ownership, and
   existing PowerShell self-test conventions. Record a read-only baseline for the
   active runtime and worktree.
2. Design a minimal attempt journal: stable run identity; unique attempt identity;
   per-attempt file paths; explicit per-phase state; and a single accepted-attempt
   pointer represented by the atomically published completed manifest.
3. Implement a same-volume temporary-manifest write, parse/validate it, and publish
   with an atomic replacement primitive. Add a fail-closed completed-manifest guard
   before Compose, probes, file creation, or metadata mutation.
4. Route all Finalize-created files, including live log followers, problem response,
   Tempo/Loki/metrics evidence, artifact inventory, and attempt metadata, beneath a
   new unique attempt directory. Keep existing generation evidence read-only.
5. Replace append-only source metadata with stable channel-keyed updates scoped to
   one attempt. Record each successful phase only in that attempt; publish completion
   only after all required phases and artifact inventory succeed.
6. Extend strict cleanup and cleanup self-tests to enumerate/remove all attempt
   directories deterministically while preserving generation evidence until cleanup
   has validated the recovery pointer and candidate root.
7. Add focused self-tests for attempt isolation, immutable partials, completion
   rejection, incomplete retry, channel deduplication, atomic publish failure points,
   cleanup of all attempts, and secret-free output.
8. Run parser, Finalize self-test, credential-scanner self-test, cleanup self-test,
   and `git diff --check`. Review the resulting harness diff independently and fix
   BLOCKER/HIGH/MEDIUM findings.
9. Against the still-running candidate runtime, execute exactly one diagnostic
   Finalize attempt using the new attempt ID. Stop on the first failed phase; never
   promote this candidate. If it passes, verify manifest/channel completion, nine-
   channel credential scan, Loki, VictoriaMetrics, and artifact scan.
10. Only after focused proof and independent review, run strict elevated cleanup and
    verify containers/network, runtime TLS, recovery pointer, attempt evidence,
    protected volumes, and exact CA absence. Then create a new candidate only if the
    user-authorized M19 workflow continues.

## Acceptance

- A failed attempt leaves its files byte-for-byte unchanged after a later attempt.
- A retry uses a distinct attempt ID and does not duplicate Loki, Tempo,
  VictoriaMetrics, or runtime-channel metadata.
- An incomplete manifest permits a new attempt; a completed manifest rejects one
  before any side effect.
- Simulated pre-publication failure leaves the prior manifest intact and no partial
  completion marker; publication is atomic.
- Cleanup removes all attempts and the recovery pointer deterministically while
  preserving both protected M19 volumes.
- All focused self-tests, PowerShell parsing, `git diff --check`, and independent
  review pass with zero BLOCKER, HIGH, or MEDIUM findings.
- The active runtime proof is diagnostic only and does not change candidate status.

## Current State

- Candidate `f0fb022ba2ab4b7a81f366b4e0e0c4d4` is diagnostic-only if harness source
  changes.
- Current manifest is incomplete; prior Finalize outputs exist at fixed paths.
- Finalize now allocates GUID-scoped attempt directories, writes new artifacts with
  create-new semantics, records per-attempt phase/source state atomically, and only
  publishes a single accepted attempt on completion.
- Process launch intents and PID/name/start records are attempt-scoped. Recovery
  stops recorded followers before retry; orphan launch intents fail closed. Cleanup
  retains the capture root and recovery pointer if follower termination is unproven.
- Parser, Finalize attempt self-test, credential-scanner self-test, cleanup self-test,
  and `git diff --check` pass after the current harness edits. Independent review
  completed with zero BLOCKER/HIGH/MEDIUM findings.
- One authorized diagnostic Finalize attempt ran under attempt ID
  `20413fa7499d4caaa1eb8e3aaf39693d`. Tempo search passed (5 intervals, 10,643
  traces); Tempo detail stopped with sanitized `failure_class=transport`. No later
  Finalize phase ran. The root cause remains unproven, and this candidate remains
  diagnostic-only. Per the stop condition, no cleanup or retry has run.

## Design Decision

- Preserve the existing v2 manifest compatibility for the credential scanner, but
  add an `attempts` map keyed by GUID-N attempt ID and an `acceptedAttemptId` pointer.
- Serialize Finalize with an exclusive lock file opened without truncation. Check
  the completed/accepted guard after acquiring the lock and before Compose, probes,
  or evidence writes.
- Put every Finalize-owned output and process record under
  `finalize-attempts/<attempt-id>/`. Never reuse fixed filenames from the capture
  root. Keep browser and generation captures as read-only shared inputs.
- Persist phase state through a same-directory temporary manifest candidate, parse
  and validate identity/schema, flush it, then atomically replace the current
  manifest. Completed publication also promotes that attempt's channel maps into
  the existing v2 top-level fields in the same atomic replacement.
- Each attempt owns keyed channel/source maps. The accepted manifest is built from
  one attempt only; Loki, Tempo, and VictoriaMetrics are never appended across
  attempts. Existing failed-attempt entries and files remain unchanged.
- On process recovery, classify stale `running` entries as interrupted and stop
  only followers whose recorded PID/name/start time still match. Cleanup recursively
  validates attempt IDs and process records before removing the capture root; the
  recovery pointer remains until all owned files are gone.
- The focused self-test uses temporary roots and synthetic sentinel strings only.
  It injects a failure after candidate-manifest validation but before atomic rename
  to prove the published manifest remains unchanged.

## Tempo-only diagnostic update

The exact trace set from the failed Finalize was not persisted. A new in-memory set
of 16,516 traces was used for a paired fresh-client/shared-client diagnostic. Both
modes received HTTP 200 for 9,822 detail responses and then stopped at the unchanged
64 MiB aggregate bound with over 60 seconds remaining in the 150-second deadline.
Fresh-client `TIME_WAIT` grew with requests; shared-client reused one established
connection. Neither mode reproduced a transport exception, so client lifetime is not
proven as the cause of the earlier failure. No Finalize, other gate, cleanup, or
client-lifetime source change followed this comparison.

## Frozen-set Tempo comparison — 2026-09-29

The exact older trace set was unavailable. A new ordered set of 18,537 traces was
frozen privately (SHA-256 `971747b5ecaf50109028a7d5b734b7a3c172aa8ad4a2a6bea716b6b069e1a6f7`)
and used unchanged in both serial modes. Fresh-client mode stopped at detail 10,550
with 72,077,151 bytes, `HttpRequestException` / `SocketException.AddressAlreadyInUse`,
and 45 seconds left on the 150-second budget. Shared-client mode reached 16,668 details
and 105,718,160 bytes, then hit the same 150-second overall deadline without transport
failure. It used at most one established TCP connection in periodic samples; all other
sampled states were zero. Fresh-mode samples found no matching connections.

The full byte size remains unknown. The deadline is a measured scalability blocker;
the strict same-set condition for attributing the fresh-mode socket error to client
lifecycle was not met because shared mode did not complete. No client-lifetime or limit
change is justified by this comparison. The active runtime remains untouched and the
candidate remains diagnostic-only.

## New frozen-set Tempo comparison — 2026-09-29

A new private ordered set was created after the older 18,537-ID file proved
unavailable. It contains 19,752 IDs (651,815 bytes), created
`2026-09-29T21:22:34.0462869+00:00`, SHA-256
`2c526a826e506ee35b06ce261468ef11b1a89e165a72b8107ecd46de3e048583`, and remains at
`.runtime/m19/tempo-experiment-bd95fa4290b9461abc51df7ec6596cb2/ordered-trace-ids.private`
with owner-protected ACL. Hash/count were reverified before both runs and afterward.

Shared-client mode completed the exact set in 154.406 seconds with 126,708,587 bytes
and 11,958 largest response. Fresh-client mode on the same set failed after 14,781
details and 97,734,397 bytes at 132.973 seconds with
`HttpRequestException` / `SocketException.AddressAlreadyInUse`; HTTP status before
failure was 200. This meets the controlled-evidence condition for per-request client
lifecycle / connection churn. The 150-second global deadline is also too short because
the shared Tempo detail phase alone exceeds it. No production change was made.

Sizing proposal for review: 32 MiB target segments, four for the measured set, a finite
160 MiB channel maximum (41,063,573 bytes, 32.4%, above measurement), and a 256-segment
hard cap. Preserve complete framed records and the 64 MiB per-response bound; stream
records to ordered segment files and scan/hash incrementally across block and segment
boundaries. At 512 bytes per segment entry, the 256-entry cap adds at most 128 KiB to
the manifest; the current manifest is 84,019 bytes, within its 1 MiB limit. Memory can
remain bounded to streaming buffers and matcher overlap. These values are proposals
only and have not been implemented.

The measured detail-only lower bound is greater than 154.406 seconds. A precise global
Finalize timeout is not justified without measuring restore, capture, and search time
from the global deadline start. Tempo details consume 9.53% of the 27-minute script
budget and 8.58% of the 30-minute job budget. The prior 1,086.49-second M9–M18 total is
historical and cannot establish current full-chain budget fit. The private set remains
in place until the later strict runtime cleanup; the candidate remains diagnostic-only.

## Tempo lifecycle and bounded-channel remediation plan — 2026-09-29

### Scope and constraints

- Change only the M19 credential-evidence harness and its focused PowerShell tests.
- Reuse one decompression-enabled `HttpClient`/handler across Tempo search and serial
  detail acquisition, then dispose it at the end of that operation.
- Keep the production Finalize deadline at 150 seconds until a fresh-runtime timing
  ledger supports a decision. A separate, explicit diagnostic-only invocation may use
  300 seconds; it must not change production configuration or candidate status.
- Store every Tempo detail as a complete framed record in ordered attempt-scoped
  segments: 32 MiB rollover target, 160 MiB logical-channel cap, 256-segment cap, and
  the existing 64 MiB per-response transport cap.
- Verify segment identities, contiguous ordinals, sizes, hashes, logical byte totals,
  completion state, positive control, and credential matches with bounded streaming.
- Keep the manifest at or below 1 MiB and preserve raw capture bytes only in the
  existing private attempt directory. Cleanup remains deferred until the user requests
  it or a later explicitly authorized phase requires it.

### Execution plan

1. Add failing focused tests for shared-client lifecycle, request cancellation and
   failure behavior, framed segment rollover/bounds/integrity, cross-block and
   cross-segment scanning, metadata size, and segment cleanup discovery.
2. Implement the Tempo-only HTTP operation and segment writer/scanner; connect them to
   Finalize and the credential scanner without changing other source transports.
3. Add sanitized monotonic timings for restore, captures/problem control, Tempo search,
   detail acquisition, segment finalization/hash, Loki, VictoriaMetrics, scanner
   preparation, artifact inventory, and manifest publication. Preserve the 150-second
   production deadline.
4. Run parser and focused acquisition, scanner, resumability, cleanup, manifest-size,
   and diff checks. Preserve all unrelated dirty worktree content.
5. Obtain an independent review and require zero BLOCKER/HIGH/MEDIUM findings before
   any runtime diagnostic.
6. Verify the frozen private trace file's exact hash/count, then run one diagnostic-only
   proof against the active runtime using a separate 300-second ceiling. Measure the
   complete relevant path and persisted-source phases. Stop for review; do not run the
   full candidate, cleanup, TLS bootstrap, or unrelated gates.

### Acceptance and stop condition

- All focused tests and the independent review pass before runtime use.
- The single diagnostic run proves the exact frozen set, complete framed coverage,
  hashes/order/byte accounting, positive control, Tempo credential scan, and persisted
  source phases without transport failure.
- The timing ledger supports a bounded timeout proposal that fits the existing 27-minute
  runner and 30-minute job budgets; otherwise stop and identify removable duplicated
  setup without reducing semantic or cleanup coverage.
- Candidate `f0fb022ba2ab4b7a81f366b4e0e0c4d4` remains diagnostic-only regardless of the
  result. Stop after the diagnostic and timeout proposal for independent review.

## Remediation implementation and review — 2026-09-29

- Finalize now reuses one decompression-enabled `HttpClient`/handler for the entire
  serial Tempo search/detail operation and disposes it when that operation ends. Detail
  responses require exactly HTTP 200; HTTP 206 is rejected.
- Tempo detail records stream to complete ordered frames in 32 MiB target segments,
  with a 160 MiB logical cap, 256-segment cap, and the independent 64 MiB response cap.
  The scanner verifies framing, ordinal coverage, byte totals, SHA-256, positive control,
  sentinel encodings, run ID, and capture interval while retaining bounded memory.
- Finalize uses a monotonic deadline measured from its entry. Production remains 150
  seconds; the diagnostic-only mode remains exactly 300 seconds. Network timeouts are
  clamped to the remaining budget, local stages are checked before acceptance, and the
  atomic publisher checks the deadline immediately before rename. Publication timing
  embedded in the manifest is labeled as pre-publication; the actual duration through
  atomic publisher return is emitted as sanitized timing output because the completed
  manifest is immutable.
- A diagnostic-only marker is persisted when its attempt is created. A diagnostic
  attempt may record diagnostic completion without `acceptedAttemptId` or top-level
  `completedUtc`, cannot be promoted, and cannot later start a production attempt on the
  same evidence root.
- Focused parser, Tempo, Finalize-attempt, credential scanner, large-capture, and cleanup
  tests pass; `git diff --check` passes. An independent read-only review reports
  BLOCKER 0 / HIGH 0 / MEDIUM 0.
- The one authorized current-runtime diagnostic used attempt
  `b0d98e4bbdc3461b961716e08b1b1ff8`. Frozen set identity passed (19,752 IDs and the
  expected SHA-256). Runtime restore took 2,036 ms; problem capture 223 ms; final live
  captures 4,278 ms; Tempo search 2,567 ms; Tempo detail 164,451 ms for all 19,752
  details. Cumulative elapsed at detail completion was 177,524 ms with 122,475 ms left
  on the diagnostic ceiling.
- The attempt stopped at `tempo-segment-finalization` with sanitized
  `failure_category=validation`; no Loki, VictoriaMetrics, full credential scan, or
  later phase ran. Source inspection identifies the harness defect: `Add-ControlCapture`
  passes the writer's raw `GeordiTempoChannelInfo` to a validator that now requires
  `runId` and capture-interval fields, but the writer type carries only segment metadata.
  This is a harness validation/binding failure, not a Tempo transport failure. The
  incomplete manifest remains explicitly diagnostic-only with no acceptance/completion
  marker. The frozen trace set still matches, 13 containers and one network remain, and
  both protected volumes are present. No cleanup or retry ran. Because persisted-source
  phases did not run, there is no complete Finalize duration or timeout proposal.

### Metadata-binding remediation and second diagnostic — 2026-09-29

- `Add-ControlCapture` now creates one normalized Tempo metadata envelope from the
  segment writer fields and manifest capture context. It assigns completion time once,
  validates that envelope with explicit run/start identity, then persists the same
  object. The writer metadata remains unmodified.
- The integration regression exercises the real `Add-ControlCapture` path with a
  multi-segment writer, checks the shared object/timestamp and raw-metadata immutability,
  then validates negative mutations. Independent review first found that JSON cloning
  converted timestamps and could make negative tests pass for the wrong reason. Clones
  now preserve timestamp strings and an unchanged clone must pass before mutation tests.
  Re-review: BLOCKER 0 / HIGH 0 / MEDIUM 0. Focused parser, Tempo, scanner, large-capture,
  Finalize-attempt, cleanup, and whitespace checks pass.
- One new diagnostic attempt, `4dde19f1e67842c7a8ee2cac635e0dbf`, ran against the
  unchanged diagnostic-only runtime and exact frozen set (19,752 IDs, SHA-256
  `2c526a826e506ee35b06ce261468ef11b1a89e165a72b8107ecd46de3e048583`). The root and
  recovery pointer matched; 13 Geordi containers, one network, and both protected
  volumes were present before execution. The prior failed attempt
  `b0d98e4bbdc3461b961716e08b1b1ff8` was not reused.
- Runtime timings: restore 2,061 ms; problem capture 224 ms; final live captures
  4,287 ms; Tempo search 2,927 ms across 17 intervals; Tempo detail 164,747 ms for
  19,752 traces / 126,708,587 response bytes; segment finalization 375 ms. The frozen
  set, four complete segments, hashes, logical accounting, and positive control passed.
  Cumulative elapsed after segment finalization was 178,629 ms, leaving 121,370 ms.
- Loki readiness returned HTTP 200 (~10 ms), then the attempt stopped at `loki` with
  sanitized `failureCategory=validation`. The query response/validation subcondition
  was not retained in the failed attempt, so the precise failed predicate is unknown;
  this is not evidence of a Loki transport failure. The attempt contains no persisted
  Loki capture. VictoriaMetrics, runtime credential scan, artifact scan, and manifest
  diagnostic completion did not run. No accepted or completed marker was published.
- Stop here. Do not retry or continue gates on this runtime in this task. The candidate
  remains diagnostic-only and M19 remains `NOT READY — REMEDIATION REQUIRED`; no
  complete Finalize timing or timeout proposal can be made from this partial run.

### Loki predicate observability remediation — 2026-09-29

- Loki responses now stream to a create-new file directly under the active attempt
  directory before semantic validation. The writer enforces the existing 64 MiB cap,
  computes SHA-256 incrementally, records exact bytes, flushes/closes before returning,
  and removes only its own incomplete file after capture failure. The validator rereads
  and validates that persisted file, rechecking byte count and hash; it never depends on
  a second in-memory response copy.
- Failures write a bounded private `loki-validation.json` containing only the phase,
  stable predicate ID, category, HTTP status, byte/hash metadata, and allowlisted
  evaluation booleans/counts. Raw response bytes remain private and are not copied to
  the manifest or stdout/stderr. The failed attempt records only this sanitized record
  and stops before VictoriaMetrics. Cleanup's attempt-root traversal removes both the
  response and validation record.
- Stable IDs covered by the focused test are: `loki.readiness.status`,
  `loki.response.persisted`, `loki.response.size`, `loki.byte_accounting`,
  `loki.response.sha256`, `loki.http.status`, `loki.response.parse`,
  `loki.response.shape`, `loki.response.status`, `loki.entry.timestamp`,
  `loki.interval.valid`, `loki.result.nonempty`, `loki.result.saturated`,
  `loki.positive_control.present`, `loki.sentinel.inventory`,
  `loki.sentinel.raw`, `loki.sentinel.url`, `loki.sentinel.json`,
  `loki.sentinel.base64`, and `loki.sentinel.base64url`.
- The failure projection validates predicate IDs through a shared bounded predicate;
  its regression specifically proves numeric IDs such as `loki.response.sha256` remain
  visible in failed-attempt metadata.
- PowerShell parser, Loki persisted-evidence self-test, credential scanner self-test,
  Finalize attempt self-test, cleanup self-test, and `git diff --check` pass. The Loki
  test also verifies persistence-before-validation, create-new behavior, exact-file
  validation, immutable failure capture, size and cancellation bounds, no public raw
  response, gate ordering, and cleanup discovery.
- Fresh independent read-only review: BLOCKER 0 / HIGH 0 / MEDIUM 0. No runtime
  diagnostic, Finalize retry, cleanup, or TLS bootstrap was run for this remediation.
  This change is ready for a separately authorized focused runtime diagnostic only;
  candidate `f0fb022ba2ab4b7a81f366b4e0e0c4d4` remains diagnostic-only and M19 remains
  `NOT READY — REMEDIATION REQUIRED`.

### Fresh diagnostic candidate after Windows restart — 2026-09-30

- A distinct diagnostic candidate `6fe4e83ffaf7418ebcc7015a4c176b61` was created at
  HEAD `2601a4ee63924e843a50dc8940a8e193709e2f5b`. The worktree remained dirty and
  untouched except for this checkpoint. Owner-run elevated LocalMachine TLS bootstrap
  passed; the runtime public CA identity, native trust, TLS host, and truststore match
  were verified without recording private material. Local provenance was generated
  for the current dirty HEAD: backend JAR SHA-256
  `70a127405084372b9eec810edd62db04086fc2a4cbd53feb3a09939ea4e3a978` and security
  telemetry extension SHA-256
  `a00473a382a5dd3f0d8b23b4335c2e39f0d99e0db47b9bde7b71f3c12a54517a`.
- Focused PowerShell parser/tests for Tempo, Loki persisted evidence, credential
  scanning, Finalize attempts, and cleanup passed; `git diff --check` passed. Backend
  clean verify passed (542 tests, no failures/errors/skips); frontend tests (235),
  typecheck, lint, and build passed. Security verification, browser M19 OIDC/CSRF E2E,
  TLS, runtime preflight, OTel, metrics, traces, logs, service map, SLO, and burn-rate
  gates passed.
- The authoritative ordered chain passed M9 alert evaluation, M10 lifecycle, M11
  notification delivery, M12 scheduling and overlap, and M13 routing. It stopped in
  M14 at `M14_initial_condition_and_episode`: `M14 route A did not create
  ALERT_STARTED`. This is the first failed gate; no M15–M18 execution or Finalize
  phase followed. The output does not establish a more specific failed predicate.
- Measured M14 timing output: fixture startup/readiness 44.65 s; initial condition and
  episode 35.96 s (FAIL); fixture cleanup/restore 6.27 s. Its recorded aggregate
  included compose 37.82 s, waits 40.40 s, traffic 0.06 s, and browser 0.12 s. These
  are M14 gate timings, not a Finalize timing ledger. Tempo, Loki, VictoriaMetrics,
  credential scan, artifact scan, manifest preparation/publication, and total
  Finalize duration are NOT RUN; no timeout proposal is justified.
- At stop, 11 Geordi containers and `geordi_default` were present; the two protected
  M19 volumes were present. Cleanup was not run. No prior attempt files were changed,
  and automatic retries were zero. Next action is to diagnose the concrete M14 route-A
  lifecycle failure before authorizing another candidate run. Since the chain stopped
  before Finalize, the attempt-time `DiagnosticOnly` manifest marker was not written;
  this candidate is explicitly barred from promotion by this execution record, and
  marker completion remains unmet. M19 remains
  `M19 NOT READY — REMEDIATION REQUIRED`.
