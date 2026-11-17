# M19 — Authenticated Operator Access and Authorization Foundation

Status: IMPLEMENTATION IN PROGRESS — NOT READY FOR DEPLOYMENT

### Fresh local CI-equivalent attempt (2026-09-24, current candidate)

This checkpoint supersedes the earlier 2026-09-24 checkpoint below for the latest
local execution. HEAD remains `2601a4ee63924e843a50dc8940a8e193709e2f5b`; the dirty
worktree was preserved without reset, stash, discard, commit, push, or GitLab pipeline.
The frozen status had 119 paths (69 modified and 50 new). `git diff --check` passed
with line-ending warnings.

The current Maven `verify` passed 541 tests, PMD and SpotBugs/Find Security Bugs. The
frontend passed 235 tests, typecheck, ESLint and production build. A fresh backend image
was built from those artifacts. Maven, staging and running JAR SHA-256 values matched
(`082d7a4bf40fcdc605659186421adeee3456bf39dac3efd27ec4f6f4b97b2fdf`); the telemetry
extension and image label matched
(`44c7db976f8027437c853ad9ddb5b1a77aed50ac2104dd99a9f0106ec56582d2`). Image ID was
`sha256:c3d703dba846b2303cad9050e9f57de9542604a0e477f9f55306f66e1b5547a2`. OCI revision
is the base committed HEAD for a dirty local candidate, not an implementation revision.

A fresh CA/truststore and private evidence root were created. Compose configuration
showed the truststore and password-reference file mounted read-only at `/run/m19`; the
container could read both, and its truststore digest matched the host. Password material
was not passed in `JAVA_TOOL_OPTIONS`. The backend became healthy through this mounted
truststore, trusted TLS returned 200, authenticated preflight passed, the full M19
security smoke passed in 4.54 seconds, and real Chromium OIDC/session/CSRF/logout E2E
passed in 1.96 seconds. The security smoke initially exposed its stale 404 expectation
for anonymous POST `/api/platform`; the current filter/unit contract is 401, so only the
smoke expectation was corrected and the full smoke then passed.

The CI telemetry and semantic chain passed in 1,086.49 seconds: OTel 6.25 s, metrics
37.09 s, traces 10.49 s, logs 10.21 s, service map 9.76 s, SLO 20.13 s, burn-rate and
provider recovery 64.25 s, M9/M18 evaluation 29.89 s, M10 lifecycle 59.47 s, M11
delivery 133.68 s, M12 scheduler 229.20 s, M12 overlap 100.47 s, M13 routing 194.36 s,
and M14–M17 history 181.24 s. A single monotonic integration-script/job-equivalent
runtime was not captured, so budget fit against 27m/30m is unproven.

The current mandatory `New-GeordiCredentialEvidence.ps1 -Action Finalize` was invoked
and failed before scanning: Windows could not open the active frontend log with
`File.ReadAllText` while the Compose follower held it. Inspection also showed M14–M17
history had replaced/stopped the backend follower and stopped VictoriaMetrics before
Finalize; the M19 volumes remained. Therefore live nine-channel manifest, Tempo/Loki/
VictoriaMetrics gate, and mandatory credential gate are **NOT PASS**. No synthetic or
historical result substitutes for them. A shared-read capture fix has been applied but
was not rerun against a new full candidate execution. A separate structural artifact
recensus found 245 files, 4 archives and 1,548 entries, with no forbidden paths/entries
or private-key PEM markers; this is not a current-run sentinel scan.

The first strict cleanup attempt failed after deleting the new capture directory but
before removing runtime TLS material. Cleanup retry was made idempotent and its self-test
updated. The strict retry passed in 7.84 seconds: project containers/network, `.runtime/m19`,
truststore, CA and current recovery pointer were removed; both named M19 volumes remain.
The exact older blocked temporary directory is still present and was not bypassed.
Current status remains **M19 NOT READY — REMEDIATION REQUIRED**.

### Continuation checkpoint (2026-09-24, credential gate and cleanup status)

Work continued in the existing dirty worktree at base HEAD
`2601a4ee63924e843a50dc8940a8e193709e2f5b`. No reset, stash, discard, commit, push,
or GitLab pipeline was used. The two named M19 volumes remain present. The earlier
1,258.02-second local serial M19 plus M9–M18 run is historical evidence from before
the latest truststore transport change. It does not validate the current candidate.
The full serial sequence was not repeated in this continuation.

The mandatory CI `script` gate now creates its manifest during the run and requires
positive-controlled captures for browser, nginx access/error, backend, RFC 9457,
OTel, Collector, Tempo and publishable artifacts, plus persisted Loki and VictoriaMetrics
queries. It scans raw and encoded sentinels in text and compressed files, hashes the
artifact inventory before validating it, and rejects missing/malformed manifests,
missing controls, synthetic leaks, unavailable persisted sources and changed artifacts.
The `after_script` only prints a bounded summary from a successful gate and performs
best-effort cleanup; it cannot replace the required gate. Nginx error logging remains
disabled to prevent callback request-line disclosure; the gate checks the live setting
and the controlled denied request at ingress. Collector sanitization is checked across
traces, metrics and logs.

Local gate simulations passed for all listed negative cases and a clean manifest. The
latest clean synthetic gate completed in 15.18 seconds; this does not include runtime
capture acquisition or prove the end-to-end CI budget. All 33 PowerShell scripts parsed.
Focused Maven tests for `GeordiSecurityFilterTest` and `BoundedHttpsJsonClientTest` passed
8/8, including a password-file truststore connection to the HTTPS test issuer. Frontend
typecheck, ESLint and Playwright test discovery passed; browser E2E was not run. The
credential scanner, fail-closed gate simulations, cleanup policy self-test and Collector
sanitizer regression passed. Compose M19, M11 overlap and M12 overlap configurations and
the pinned Collector validation passed. `git diff --check` passed with line-ending
warnings only. The synthetic gate timing does not measure live provider acquisition or
prove the end-to-end CI budget. A recensus found 243 paths, 4 archives and 1,548 entries across current local
artifact roots, including staged image JARs. Those binaries predate the latest Java
truststore transport and route-order changes, so their hashes are not final candidate
provenance. Playwright E2E and backend startup through the changed mounted truststore
were not rerun because the stack was stopped. No GitLab pipeline was run; there is no
actual CI-created runtime manifest, live nine-channel scan, or measured final CI path.

The recorded TLS CA thumbprint was found in CurrentUser Root, then removed through the
project's exact-thumbprint cleanup script. Verification confirms the recorded root and
`.runtime/m19` are absent. Both named M19 volumes remain present. The exact previously
authorized old private temporary evidence directory still exists because Windows
execution policy rejected its deletion; no alternate deletion method was used. Its exact
path is `C:\Users\marce\AppData\Local\Temp\geordi-m19-4541abc4d54c4f54b765b938fd06adf2`.
The current cleanup code keeps the active run's recovery pointer outside the TLS folder,
deletes the private evidence directory before Docker status checks, and fails if the
pointer remains. Docker inventory runs in a hidden child process with a 20-second
timeout; cleanup reports timeout or inventory errors. The cleanup policy self-test
asserts this bound and ordering. A fresh independent complete diff review confirmed the
prior cleanup MEDIUM is resolved and found no new actionable findings (BLOCKER 0,
HIGH 1, MEDIUM 0, LOW 0). The remaining HIGH is acceptance evidence: the current
candidate has not been exercised through mounted-truststore startup and mandatory
Finalize against live runtime/persistence sources. The rejected old path is outside the
current-run pointer, so local successful-path cleanup remains unverified.
The current result remains **M19 NOT READY — REMEDIATION REQUIRED**.

The request inventory and routing decision are:

| Request class | Target and handling | Scripts |
| --- | --- | --- |
| Geordi liveness/readiness probes | Shared `https://geordi.localhost:8443`; anonymous, status-only | all M19-aware scripts through `scripts/lib/GeordiAuthentication.ps1` |
| Geordi APIs, including `/api/platform`, `/api/me`, telemetry, SLO and alert APIs | Same shared HTTPS origin; signed `REGRESSION` bearer identity | `verify-otel`, `verify-metrics`, `verify-traces`, `verify-logs`, `verify-service-map`, `verify-slos`, and the existing M9–M18 smokes |
| Frontend document/assets and browser routes | Same shared HTTPS origin; page/assets anonymous, proxied API requests use the authenticated API client | the six telemetry scripts plus M19 browser E2E |
| Providers and Collector | Existing direct local fixture endpoints: VictoriaMetrics 8428, Loki 3100, Tempo 3200, Collector 8888/13133 | telemetry and SLO smokes |
| Demo sources and webhook fixtures | Existing direct local fixture endpoints (8081–8084 and 18080–18083) | semantic smokes; no request is rerouted through the app ingress |

`Get-GeordiApplicationBaseUrl` is now the single source for the M19 public origin.
The shared request helper keeps probes anonymous, obtains one signed regression identity
per PowerShell process for other Geordi API calls, and only permits the documented local
fixture ports for direct provider/demo requests. `Test-GeordiRuntimePreflight.ps1` now
checks anonymous readiness, authenticated platform and identity reads, the HTTPS frontend,
and provider readiness; it is placed after TLS acceptance and before the security smoke.
The old backend/frontend host-port defaults are absent from the CI smoke scripts. A
PowerShell parser pass succeeded for all 23 scripts.

The current local run followed the CI serial sequence through backend artifact build and
provenance verification, uncached runtime/fixture image builds, TLS setup, startup, M19
security smoke and browser E2E (1/1), OTel, metrics, traces, logs, service map, SLOs and
burn-rate/provider recovery, then the ordered M9–M18 alert evaluation, lifecycle,
notification, scheduling, overlap, routing and history smokes. All passed. The final
step ledger reported 1,258.02 seconds (20m58s), within the 27-minute script budget; this
is a local CI-equivalent serial run, not a GitLab pipeline run. The preserved VictoriaMetrics
volume initially exposed old self-telemetry and M18 fixture collisions. SLO checks now
scope self-telemetry to the current backend container, and `New-GeordiM19SmokeConfig.ps1`
generates run-scoped M18 service and policy IDs in temporary config copies, so the
unchanged assertions passed without removing persisted data.

Nginx M19 globally suppresses error-log request lines that could expose OIDC callback
parameters before route selection; bounded access events remain enabled. GitLab teardown
now invokes TLS cleanup even if Compose teardown reports failure. A fresh independent
review confirmed the primary remaining HIGH: the GitLab job does not capture, require,
and scan a nine-channel private manifest as a required `script` gate. The optional
`after_script` diagnostics intentionally withhold output when that manifest is missing or
invalid, and cannot fail the main job on a discovered leak. A fresh final runtime leak scan
and mandatory CI gate remain closure blockers. Teardown also warns and exits successfully
if Compose removal fails, so the CI cleanup result is not itself enforced.

Current source artifacts rebuilt and matched their own provenance: Maven/staging/runtime
application JAR SHA-256 `d2b700c2a054e1dfeaeac659764303b5e4d4d1341dcb4be28d8eb499649227e0`;
security telemetry extension/staging/runtime SHA-256
`921c7eeb2752e1e84c338a40183c272f73f0f3aa182d64358a2a14244ff4fb4f`. Image ID is
`sha256:c1cc6302b339749879f2ef50061af926509a84e61aeaad229bd2c3ed0a49c5d5`; its revision
label is the committed base HEAD, not a source revision for the dirty candidate. Maven
`verify` passed 540 tests, PMD, SpotBugs and Find Security Bugs. Frontend gates passed 235
tests, typecheck, ESLint and production build. The build reports an existing large-chunk
warning. No comprehensive post-run artifact census or fresh nine-channel runtime scan was
completed in this continuation; prior nine-channel and persistence scans remain separate
evidence and are not being re-claimed as a fresh run.

The post-run publishable-artifact census covered the CI report directories, frontend
`dist`, staged/build JARs, verification properties, and OpenAPI: 243 files, 63,477,024
bytes, and 4 archives containing 1,548 entries. Archive paths contained no OIDC fixture
package or private-key/certificate bundle entries. The Maven/staged application JAR SHA-256
matched at `d2b700c2a054e1dfeaeac659764303b5e4d4d1341dcb4be28d8eb499649227e0`; the
security telemetry extension/staged SHA-256 matched at
`921c7eeb2752e1e84c338a40183c272f73f0f3aa182d64358a2a14244ff4fb4f`. This inventory
does not substitute for sentinel matching against freshly captured runtime channels.

The current run's generated synthetic telemetry remains in the preserved provider volume,
as expected for the authored semantic fixtures. The final candidate remains **M19 NOT
READY — REMEDIATION REQUIRED**: the required runtime leak scan/CI gate is unresolved, a
post-run artifact census has not been repeated, and ephemeral TLS cleanup is still
unverified in this Windows session. The local regression did pass; the milestone is not
being reported complete.

### Continuation checkpoint (2026-09-24, local runtime evidence)

The previous checkpoint's `UNVERIFIED` leak-scan and diagnostic statements are
superseded by this evidence. Work remained in the existing dirty worktree at baseline
`2601a4ee63924e843a50dc8940a8e193709e2f5b`; no reset, stash, discard, commit, push,
or GitLab pipeline was used. Both M19 named volumes were retained.

An isolated private manifest exercised all nine required channels (browser console,
nginx access, nginx error, backend logs, RFC9457 problem responses, exported OTel,
Collector debug, Tempo query/persisted trace, and publishable CI artifacts) with a
channel-specific positive control. The credential scanner passed with zero raw,
URL-encoded, JSON-escaped, base64, or base64url matches in every channel. Loki was
queried independently and passed as additional persisted-source evidence. VictoriaMetrics
was independently enumerated (14,988 series), normalized to structured series records,
and passed the same sentinel scan; its volume was not altered. The metrics pipeline had
initially omitted `attributes/security`, allowing test OAuth state/code in Collector
debug output. Adding that processor to the metrics pipeline fixed the live leak; the
Collector config validated and the new runtime passed the bounded scans. The nginx
error-log channel now has an actual controlled upstream-resolution warning positive
control and remains credential-free.

`Write-GeordiSafeDiagnostics.ps1` was run against the valid private manifest. Its
captured output contained nine per-channel PASS results, both persistence results, and
sanitized container-state counts. The final bounded captures also passed the scanner.
The publishable-artifact inventory covered 240 files, including reports, frontend build
output and staged application artifacts. ZIP/JAR inspection covered 756 entries and
found no OIDC fixture class/package, private key, PFX/P12, or `.runtime/m19` entry. The
temporary scanner control marker was removed from artifact staging after use. The final
artifact recensus and scan must be repeated after all local output updates and before
cleanup.

Runtime contract evidence: anonymous GET/HEAD liveness and readiness returned 200 with
status-only GET bodies and empty HEAD bodies; anonymous `/actuator/health` returned
401, while `/actuator` and `/actuator/metrics` returned 404. `RoutePermissionPolicyTest`
enumerates 21 application reads plus detailed health for GET/HEAD, exact ACK/EVALUATE,
session-only CSRF/logout, probes, login/callback and default-deny path/method cases.
`GeordiSecurityFilterTest` covers missing/invalid bearer (401), unknown route (404),
permission/origin/CSRF denials (403), callback browser binding and canonical `/api/me`.
`SecurityPropertiesTest`, `OidcMetadataClientTest`, `TrustedJwksKeyCacheTest`, and
`BoundedHttpsJsonClientTest` cover fail-closed configuration/discovery/key refresh and
bounded dependency responses; no separate full live startup-failure matrix was run.
OpenAPI 3.1 remains lint/bundle-valid from the prior evidence and declares bearer,
session, logout CSRF, OIDC callbacks and probes. Production package inspection confirms
the test IdP is excluded from the backend artifact.

The local CI-critical-path attempt is **not a valid complete measurement**. The first
literal run stopped at `verify-otel.ps1`: its default `127.0.0.1:8080` bypasses M19's
TLS ingress and that port is intentionally unpublished. Temporary, uncommitted harness
adaptations established that deployment config (4.5 s), TLS (0.8 s), security (3.4 s),
browser E2E (1.9 s), OTel (4.0 s) and metric ingestion/persistence work, but metrics'
remaining API/frontend assertions target the pre-M19 `127.0.0.1:3000` and unauthenticated
backend defaults. The existing trace/log/service-map scripts share these assumptions.
Attempts stopped at those harness boundaries; no historic durations are summed and no
claim is made against the 27-minute script/30-minute job limits. Reproducing the complete
serial M9–M18 chain faithfully requires an approved CI harness adaptation, outside this
continuation's limited scope.

Remaining closure gates: repeat final provenance and artifact sweep after documentation,
complete an executable full-path 27m/30m critical-path measurement, finish cleanup of
containers/network/ephemeral trust and private captures while preserving the two M19
volumes, and perform a fresh independent final implementation review. Status therefore
remains **M19 NOT READY — REMEDIATION REQUIRED**.

### Continuation checkpoint (2026-09-23, latest)

This checkpoint supersedes the earlier continuation notes below, which remain as a
chronological implementation record. No reset, stash, discard, commit, or push was
performed. The baseline remains `2601a4ee63924e843a50dc8940a8e193709e2f5b`.

The PowerShell HTTPS failure came from scriptblock delegates running on asynchronous
threads without a reliable PowerShell runspace, compounded by separate low-level client
construction in the smokes. The shared helper now uses strongly typed C# socket and
certificate delegates, keeps the logical HTTPS host for SNI, and performs normal CA and
SAN validation. The original exception type was not captured before replacing that
path. Transport preflight passed anonymous readiness and authenticated `/api/platform`
and `/api/me`; the authenticated M12 API subset remained green.

The full history chain passed: M14 episode start/resolve, identity and restart durability;
M15 proxy/history/UI behavior; M16 authenticated ACK attribution, replay and conflicts;
and M17 routing dispositions, outbox, privacy, legacy projection and sanitized failure.
Combined duration was 179 s. The reset and cleanup validated and touched only exact M14
containers and `geordi_m14-*` volumes. Both M19 volumes were preserved.

Authenticated semantic runtime evidence now includes M9 burn-rate (about 128 s), M9/M18 evaluation and imported multiwindow evidence (66.7 s), M10 durable lifecycle and provider outage/recovery (57.8 s), M11 notification delivery/retry/restart and secret isolation (140.1 s on the latest cleanup-safe rerun), M12 scheduler firing/outage/recovery/restart (230.9 s on the latest rerun), and M13 isolated routing/disposition/outbox proof (181.3 s). The deterministic M12 manual/scheduler overlap proof passed in 102.3 s using a test-only provider barrier: OPERATOR received 403, overlapping EVALUATOR received 409, and barrier release yielded exactly one transition, one MATCHED disposition, and one delivery. M18 is covered by the 66.7 s evaluation smoke. The M19 security smoke passed again in 54.7 s, including malformed signature, wrong audience, ID token, duplicate Authorization/session, and ACK provenance checks.

PowerShell AST parsing passed for all `scripts/*.ps1`; Python syntax passed for the test-only M12 overlap proxy. Nine Compose combinations passed `config --quiet`. The credential scanner self-test passed; it is not runtime leak evidence. The authenticated semantic runtime chain and deterministic overlap passed earlier and were not repeated because this turn changed no product behavior.

The stale-image cause was confirmed: the prior `geordi-backend:local` image had no verified artifact labels and contained a JAR digest different from Maven output. The backend Dockerfile's `ci-runtime` target stages from `backend/.ci-artifact`; this directory held stale CI artifacts from an earlier build. I copied the current Maven JAR and telemetry extension into that ignored staging directory, supplied their computed digests and the actual base HEAD through local build arguments, and built the existing verified target with `--no-cache`. No product code was changed. Provenance now matches: Maven JAR, build-context staging JAR, verified digest label and runtime-container JAR all equal `1ef2c5b09348131bdc9ac4dcffa2ea8e65ea259072bc2ac2afa513d6743ffdc8`. Telemetry extension and image label both equal `921c7eeb2752e1e84c338a40183c272f73f0f3aa182d64358a2a14244ff4fb4f`. Image ID is `sha256:7ccc579d76c294329e60d1746a86ee12120ee33256fbf52b0399b6972f7a5118`; artifact and extension labels match those digests. OCI revision is `2601a4ee63924e843a50dc8940a8e193709e2f5b`: this is the committed base HEAD for a dirty local M19 candidate, not an authoritative implementation revision or reproducible source revision.

Against that rebuilt image, anonymous liveness/readiness and authenticated `/api/platform` and `/api/me` returned 200; Windows-native TLS acceptance passed; the M19 security smoke passed; Chromium OIDC/session/CSRF/logout E2E passed 1/1. Redocly OpenAPI 3.1 lint and bundle validation passed with 11 recommended-style warnings and no validation/reference errors. Existing Maven `verify` evidence remains 540 tests with PMD, SpotBugs, Find Security Bugs and ArchUnit green; frontend evidence remains 235 tests, typecheck, ESLint and build green. Deployment evidence recorded before this continuation includes Compose, Collector, Tempo and Loki config acceptance and the V8 compatibility suite. Startup fail-closed assertions are covered by SecurityProperties and OIDC metadata/cache tests, not a separate live startup matrix in this turn.

A private temporary capture was used to exercise and inspect actual browser/frontend logs, nginx access records, backend security logs, sanitized RFC9457 bodies, Collector debug export and a Tempo query/trace. For each captured file, 0 raw/URL/base64/base64url/JSON sentinel matches were found. These exploratory captures did not satisfy the required manifest's channel-specific positive-control contract and therefore are NOT a runtime nine-channel PASS. The current M19 nginx config explicitly sends error logs to `/dev/null`, so nginx error has no observable positive control. CI diagnostics withheld output when the manifest failed validation; the GitLab `after_script` sequence is not a demonstrated failure capture path. Browser-client-secret and several protocol sentinels were not safely injected into every real channel. No capture is retained after cleanup. Result: runtime nine-channel scan UNVERIFIED; sanitized failure diagnostic scan UNVERIFIED. Artifact scan confirmed current `.ci-artifact` JARs match the expected built digests, but no comprehensive scan of every publishable frontend/test/report/archive path was completed.

The CI script sequence in `.gitlab-ci.yml` remains unexecuted. Recorded historic individual durations: PKI generation/trust setup not timed in this turn; stack startup not timed separately; browser E2E 1.2 s; rebuilt-image M19 smoke 4.0 s; TLS acceptance under 1 s; provenance build about 10 s after staging; nine-channel scan has no valid duration; final stop/PKI cleanup about 30 s. M9 128 s, M9/M18 66.7 s, M10 57.8 s, M11 140.1 s, M12 230.9 s, overlap 102.3 s, M13 181.3 s, M14–M17 179 s. The integration CI critical path shares one startup and TLS initialization, then serially runs the E2E, telemetry checks and semantic scripts listed in `.gitlab-ci.yml`; independent historical local durations cannot be summed as a measured GitLab path. No full critical-path measurement or timeout suitability proof exists against RUNNER_SCRIPT_TIMEOUT 27m and job timeout 30m.

Cleanup stopped project containers and removed the `geordi_default` network without deleting volumes. `Remove-GeordiTestTls.ps1` verified the exact imported CurrentUser CA thumbprint absent and removed `.runtime/m19` keys/secrets/truststore. Private capture and staging temp directories were removed. Both `geordi_m19-alert-lifecycle-data` and `geordi_m19-victoriametrics-data` remain present with expected labels; lifecycle data is preserved for ACK/lifecycle provenance and the provider volume is preserved by default for controlled telemetry.

Local closure remains blocked by the unverified nine-channel runtime scan and failure diagnostics, incomplete publishable-artifact sweep, remaining contract inventory (including detailed actuator/startup matrix evidence), unmeasured CI critical path, and missing complete fresh independent milestone review. The authenticated semantic chain was not rerun because no relevant product behavior changed. GitLab pipeline was not run, as instructed.
The milestone remains **M19 NOT READY — REMEDIATION REQUIRED**.

## Current worktree runtime checkpoint (2026-09-23)

The implementation remains uncommitted in the current worktree. No reset, stash,
commit, or push was performed. The required M19 Compose overlay now builds and runs a
development-only HTTPS OIDC fixture, an ephemeral CA/truststore, a TLS frontend ingress
on `127.0.0.1:8443`, and the backend without a published host port. Compose renders
successfully; the backend, frontend, OIDC fixture, and existing observability/demo
services reached healthy status. The fixture is isolated from the backend artifact.

Runtime evidence gathered: Java HTTPS discovery and JWKS requests to
`https://auth.localhost` returned 200 from the backend container using the mounted
ephemeral CA truststore; unauthenticated liveness/readiness returned 200 and an
unauthenticated `/api/platform` request returned 401 from the backend. The fixture
control endpoint issued a short-lived OPERATOR access token. The frontend TLS ingress
healthcheck is healthy. PowerShell 7 generated the ephemeral CA and imported it into
CurrentUser Root for the browser smoke; the cleanup script removed it and its recorded
thumbprint after testing. Chromium loaded the real TLS frontend with certificate checks
enabled and the M19 E2E reached the fixture authorization endpoint. The login did not
complete the callback to `geordi.localhost:8443`; Playwright ended at the issuer rather
than at the application. A process-specific DNS rule cannot map hostnames to alternate
ports, so the committed E2E configuration still needs a reliable loopback resolver /
ingress arrangement before its full OIDC, session, CSRF and logout assertions pass. No
TLS verification bypass was used.

The M19 Playwright test and isolated config now run Chromium with normal CA and hostname
verification; its host resolver rule is scoped to this browser process. The first
instrumented run localized the failure to the fixture authorization request: Geordi sent
the exact callback `https://geordi.localhost:8443/login/oauth2/code/geordi`, while the
fixture accepted only the same URI without port 8443. The fixture returned 400 and
generated no redirect. The fixture's exact allow-listed redirect URI was corrected to
include 8443; no protocol validation was relaxed.

After that one-line correction, the real Chromium browser flow passed end-to-end. The
browser reached the fixture's trusted HTTPS authorization endpoint, the fixture
accepted client/redirect/code/PKCE request and redirected to the exact callback, nginx
logged the explicit `callback` route with 302, and backend security telemetry recorded
SESSION authentication success. The callback's Set-Cookie response retained both the
binding-cookie deletion and session cookie. Browser assertions verified the binding
cookie name was sent at callback and then absent, session cookie host/path/Secure/
HttpOnly/SameSite=Lax properties, no Domain attribute on either cookie, the final exact
root URL without query, expected `/api/me` principal and permissions, and no OAuth
credential-like key in local/session storage. CSRF bootstrap returned 200; POST logout
without CSRF returned 403; the same POST through the frontend with CSRF returned 204;
afterward `/api/me` returned 401 and the protected read returned 401. Playwright passed
1 real-browser test. No HAR, trace or video was produced.

Focused existing backend regression tests cover missing/wrong/duplicate binding,
short-lived host-only Secure cookie shape, state extraction/duplicate rejection,
single-use transaction claim, session rotation/capacity/expiry, callback code+PKCE, and
canonical `/api/me` session creation. The production code still uses the binding cookie
before consuming state, and nginx has an explicit `/login/oauth2/` proxy location; the
runtime callback 302 and session creation demonstrate the route reaches the backend,
not SPA fallback. Frontend validation after these additions passed typecheck, ESLint,
all 234 Vitest tests (27 files) and production build. The build reports the existing
large main chunk warning. Browser/CSRF/logout gates for this iteration are now green;
the remaining security ambiguity gates and authenticated M9–M18 chain, actual runtime leak
scan, full timings/provenance, and final independent review remain open, so M19 remains
NOT READY.

A reusable PowerShell helper now obtains short-lived signed fixture tokens for VIEWER,
OPERATOR, EVALUATOR and REGRESSION in process memory, validates the ephemeral CA and
hostname, renews before expiry, sends each request once, and keeps endpoint routing safe
for parallel runspaces. The M19 overlay uses a dedicated, non-root-writable lifecycle
volume and catalogs. `verify-security.ps1` passed the live Compose smoke for status-only
anonymous probes, anonymous read denial, signed VIEWER read/ACK denial, OPERATOR ACK
validation/provenance/replay/conflicts, EVALUATOR lifecycle and OPERATOR lifecycle denial,
plus unmatched method and actuator denial. Nginx was corrected to deny unknown actuator
paths instead of serving the SPA fallback. This smoke covers only its listed assertions;
the remaining malformed/ambiguous credential and scheduler exclusion assertions remain open.
The independent reviewer pass on this continuation delta reported BLOCKER 0 / HIGH 0 / MEDIUM 0 after fixes for probe-schema exactness, redirect replay, and actuator fallback. It was a delta review, not full milestone closure review.


The authenticated M9–M18 regression chain remains unadapted and unrun. The active nine-channel
leak proof remains incomplete because no full-stack capture manifest and positive controls
have been gathered. Runtime budget, cleanup ledger, artifact provenance and fresh final
independent review are still open. The scanner self-test is not runtime leak evidence.
The source fixture now has an alternate local browser listener on port 9445 and its
discovery advertises the authorization endpoint at that port for local browser use;
Compose publishes it only on loopback. The browser listener, exact redirect URI, and
callback/session path passed the real Chromium E2E in an earlier run. A fresh repeat in this continuation was blocked at initial navigation by Chromium `ERR_CERT_AUTHORITY_INVALID` even after importing the ephemeral CA into CurrentUser Root; the flow did not start in that repeat. Compose was stopped without deleting its volumes; the generated TLS/runtime directory and recorded CurrentUser Root CA were removed with the cleanup script. The final stack is stopped.

Current runtime closure gates are **NOT SATISFIED**. This checkpoint is evidence of
partial integration only and does not claim M19 local closure or authoritative CI
validation. The final fresh reviewer pass required by the runtime closure directive has
not yet been performed.

TLS trust bootstrap follow-up (2026-09-23): the earlier `ERR_CERT_AUTHORITY_INVALID`
repeat was not evidence of an OIDC protocol regression. The prior launch path did not
require proof that the exact generated CA thumbprint was present in CurrentUser Root and
that Windows TLS had accepted the running ingress before Chromium started. The trust
helper now verifies leaf signatures against the exact ephemeral CA, expected SANs, exact
store thumbprint, and Windows-native HTTPS. Endpoint TLS verification is a separate
bounded step after services become healthy; it maps only the TCP socket to loopback while
retaining the original `geordi.localhost` TLS hostname and normal OS chain validation.
Playwright starts a fresh Chromium process with its default fresh temporary context and
no certificate bypass. Two independent CA generation/import/start/Windows-TLS/Chromium
E2E/cleanup cycles passed. Each cleanup removed the exact recorded thumbprint and verified
absence. The latest E2E after final backend image rebuild also passed.

The complete isolated M19 smoke passed again after the final invalid-signature probe correction in 45.369 s:
status-only anonymous probes, anonymous protected denial, VIEWER read/ACK denial,
OPERATOR actor rejection and authenticated ACK provenance/create/replay/conflicts,
EVALUATOR lifecycle/OPERATOR denial, invalid signature, wrong audience, ID token,
duplicate Authorization, duplicate session cookie, and unknown session cookie with a
valid bearer. The browser E2E separately proves session-plus-bearer rejection and hostile
Forwarded/X-Forwarded identity stability. Scheduler execution and shared exclusion remain
covered by the M12 semantic smoke, which is not yet adapted to the TLS-only M19 ingress
and has not been run in this final topology.

Local quality gates after implementation changes: Maven `verify` passed 540 tests with
zero failures/errors/skips, PMD passed, SpotBugs/Find Security Bugs reported zero findings,
and ArchUnit ran within the test suite. Frontend passed all 234 Vitest tests, typecheck,
ESLint, production build, and the real Chromium E2E. Compose configuration passed for
M19, M12, and M13 (M13 used non-secret validation-only interpolation values). Credential
scanner self-test passed; this is not runtime leak evidence.

Artifact provenance from the final Maven output and rebuilt local image: built, verified,
and running application JAR hashes all equal
`c9311dcd11c33cec85eefb5b8d23a891ff55fda46ec7d315e8708824775837b7`. Image ID is
`sha256:0d14bbdf2cef3b4394114f6a366ae4facc97754316f614d0855b918b98e2754a`; OCI verified
artifact and telemetry-extension digest labels match their local files. OCI revision is
`2601a4ee63924e843a50dc8940a8e193709e2f5b`, which identifies baseline HEAD plus uncommitted
M19 work; it is not an authoritative candidate revision. The pre-existing
`backend/.ci-artifact` directory was preserved; provenance used a separate temporary
build context.

The fresh supported-model independent review of the final TLS/auth/smoke delta reported BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0 after two fixes: the invalid-signature case now changes a significant first base64url character, and TLS failure diagnostics retain only a sanitized category and last HTTP status. This focused review is not a full milestone review. Caveman review was applied to this delta.

The retained volume inventory is explicit: `geordi_m19-alert-lifecycle-data` is
PRESERVE_FOR_DURABILITY because it retains authenticated ACK/lifecycle provenance and
idempotent replay evidence; `geordi_m19-victoriametrics-data` is
PRESERVE_BY_DEFAULT; reset it only when a fresh isolated M19 provider timeline is
specifically required, because it contains controlled smoke telemetry. The M9–M18
smokes use their own milestone-specific provider volumes and reset rules. Neither M19
volume is consumed by the M9-M18 chain; M12/M13 and other milestone volumes remain
governed by their existing script validation/reset rules. `docker compose down` preserved
both M19 volumes.
Full authenticated M9-M18 execution, positive-controlled runtime leak scan, complete
timing ledger, sanitized failure-path capture, full deployment/config contract gates,
and complete final independent review remain open. Current result remains
**M19 NOT READY — REMEDIATION REQUIRED**.

## Implementation execution record

Implementation started from `2601a4ee63924e843a50dc8940a8e193709e2f5b`.
HEAD, local main and origin/main matched exactly and the worktree was clean before
editing. The older planning SHA below records the pre-plan runtime baseline; the
only intervening commit added this plan. A fresh independent read-only baseline
review found no material schema/API/lifecycle-wiring contradiction.

Execution follows Slices 0–14 below without changing their authority. Affected areas
are core application contracts, Alerts attribution/application/adapters, bootstrap
security, self-observability, frontend auth, test-only IdP/TLS, Compose/CI/scripts,
OpenAPI and the listed documentation. No M20 work, commit or push is authorized.

Slice 0 passed before domain/persistence edits: the frozen V7 SQL/API projections
round-trip Unicode, null reason and nanosecond timestamps. Existing normalization,
ACK/RESOLVE serialization and replay tests pass. Java 21 Maven clean verify passed
439 tests (438 existing plus one frozen compatibility test), PMD, SpotBugs/Find
Security Bugs (zero findings), and 21 existing ArchUnit tests in 4m45s. Frontend
baseline passed npm ci, 225 tests, typecheck, ESLint and production build.
These are baseline/foundation results, not M19 runtime closure or integration timing.
Slice 1 initial focused suite passed 75 tests, including 22 ArchUnit rules and the
unchanged legacy/concurrency suite. Core identity, immutable permissions, mechanisms,
permission checks and Alerts-owned attribution are implemented. Incremental review
found one MEDIUM (URI parser exceptions retained raw issuer); bounded replacement
exceptions and sentinel tests address it. The review also requested the EVALUATE-only
permission case, now added alongside ACK-only. All 22 affected tests passed on
revalidation. Slice 1 foundation gate passed; later application-wrapper/wiring
coverage remains assigned to Slices 7–9 as planned.
Slice 2 passed 82 focused tests including 22 ArchUnit rules: additive V8, frozen
legacy reads/old INSERT defaults, 72 SQL constraint combinations, older migration
boundaries, supplementary Unicode, corrupt-row bounded failures, durable restart,
authenticated replay/name snapshot preservation and both legacy/authenticated
ACK/RESOLVE races. The internal authenticated writer uses the existing episode-row
transaction boundary. Public ACK cutover is still deferred to Slices 7–8. V7-only
notification migration tests now explicitly target V7, preserving their original gate.
Slice 3 implemented strict configuration/grant mapping, bounded observation
contracts, source-side agent exporter sanitization, Collector defense, safe diagnostic
foundations and private sentinel scanner. Configuration tests and its focused Maven
verify passed. The pinned Collector 0.157.0 accepted the actual attributes/security
configuration after replacing span-only service matching with resource matching shared
by traces and logs.
Scanner self-test passed nine positive channels and one synthetic negative control;
this is not evidence of actual browser/Compose/Tempo/CI channel cleanliness.
The pinned 2.28.1 Java agent and thin extension were then loaded by the Java 21
backend in an isolated container with a live Collector detailed-debug exporter. A
request carrying a query-string sentinel produced a backend span (`service.name` was
`geordi-backend`, one active span arrived, and the fixed span name was `GET`); three
attributes were dropped and the sentinel was absent from both backend logs and the
Collector output. This closes the extension-load/source-exporter smoke only; it does
not establish the complete nine-channel leak proof, frontend/nginx TLS behavior,
downstream client cases, or runtime authentication. The temporary containers, network,
and config were removed.
Runtime composition is now wired through the Spring request chain, controllers,
scheduler and frontend. Slice 4 provides an ephemeral-CA loopback HTTPS IdP for backend
integration tests; the deployment/Compose-shared development OIDC fixture, TLS ingress,
and browser OIDC/session/CSRF/logout E2E now pass locally. Slices 5–6 provide the strict RS256/RFC 9068 adapter,
JWKS cache, OIDC discovery, code+PKCE flow, ID-token validation, bounded sessions and
CSRF lifecycle. Slices 7–9 provide the exact route/method filter, mutation guards,
credential-free scheduler entry, authenticated ACK attribution and `/api/me`/CSRF/logout
protocol. Slice 10 provides frontend auth readiness, permission gates, logout teardown,
and generation/cache isolation across session changes. Targeted tests exercise these
boundaries and the HTTPS test issuer, and the full test/static gates are recorded below.
Slice 11 has source-side sanitization, Collector defense and a scanner self-test, but the
full active leak proof across browser/nginx/storage/export/artifacts is absent. Slices
12–14 remain incomplete: no authenticated M9–M18 regression chain, measured CI budget /
cleanup evidence, artifact provenance, complete browser/runtime smoke or closure record
exists. Java 21 is run through the existing CI Maven image with a Linux repository path;
host Maven settings use a Windows-only repository path.

Frozen fixture SHA-256 values (before persistence edits):
- `ack-v7.sql`: `ADBC51BBB0EB0F2C2D241772533C9403E63AE233FF7C1910C5672116406A08A7`.
- `ack-v7-api.json`: `CE561DA34010A18A8FA901DDB2D371F57014BE09910180FAC80631D240506881`.

The configured reviewer could not start because its fixed `gpt-5.6` was unavailable;
the user-authorized fresh `gpt-6-astra` read-only fallback performed baseline and final
implementation reviews. No findings remain at BLOCKER, HIGH or MEDIUM severity. Other
unavailable specialized-agent work remained in the main session, as requested by the
owner.
Applied skills: `lean-build` (scope and existing-boundary preservation),
`investigate-first` (container Maven path failure), `migration` (V8 preparation).

### Continued implementation record — 2026-09-22

The strict protocol pieces now have a required Spring composition: configured issuer
discovery and initial JWKS retrieval complete before the servlet filter is registered;
missing properties, secret file, metadata or signing keys prevent startup. The filter is
registered at highest precedence for REQUEST/ERROR, exact health details remain hidden,
and session cleanup is scheduled every 60 seconds. This composition deliberately has no
authentication-disable switch. A shared backend test initializer now starts a loopback
HTTPS OIDC issuer with ephemeral key material, trusts its generated certificate through
a temporary JVM truststore, and supplies a signed integration bearer. Existing Spring
integration contexts use it, and an end-to-end test follows discovery, TLS verification,
PKCE, browser-state binding, client-secret-basic exchange, ID-token validation, session
creation and `/api/me`. The fixture is test-only; it is not yet shared with Compose. The
development Compose stack still lacks its required fixture configuration and is not yet
an M19-supported startup path.

The Alerts HTTP acknowledgement now accepts only a reason, derives durable identity and
display attribution from the authenticated principal, and depends on the authorized
application interface. ArchUnit forbids the web adapter from depending on the legacy
caller-asserted entry. The response distinguishes legacy/authenticated attribution, and
`/api/me` includes the canonical auth mode. The frontend checks `/api/me` before mounting
protected views, fails closed without read permission, gates ACK/evaluate actions by
their exact permissions, obtains a session CSRF token in memory for mutations, clears
query state on logout, removes actor entry and labels legacy history truthfully. OpenAPI
now identifies M19 security schemes, auth routes, CSRF requirements and ACK attribution.

Incremental implementation review findings were corrected with regressions, including
OIDC callback browser binding, same-principal CSRF recovery, expired-JWKS refresh
concurrency, a total Java 21 HTTPS body deadline, case-insensitive Bearer challenges,
late frontend response/mutation invalidation, and cache isolation across principal
changes. The fresh final reviewer reported **BLOCKER 0 / HIGH 0 / MEDIUM 0**.

Backend Java 21 `mvn verify` passed **540 tests**, PMD, and SpotBugs/Find Security Bugs
with zero findings. Frontend passed **234 tests**, typecheck, ESLint, and production
build; Vite retains the existing >500 kB main-chunk warning. Focused HTTPS slow-body,
JWKS-expiry concurrency and filter tests passed. `docker compose config --quiet`, OpenAPI
YAML parsing, `git diff --check`, and the credential-scanner self-test (9 positive
channels, including rejection of text/compressed leaks) passed. This scanner self-test
is not the full active pipeline/artifact leak proof.

Historical checkpoint (before the local Compose/browser continuation): the authenticated
M9–M18 chain, measured CI budget / cleanup, full runtime/browser leak proof and artifact
provenance had not run. At that earlier point TLS ingress and a Compose-shared OIDC
fixture were also absent. Those infrastructure/browser gates have since been implemented;
the real Chromium OIDC/session/CSRF/logout E2E passes. M19 remains NOT READY because the
broader semantic, active runtime leak, timing, provenance and closure gates remain open.

## Planning authority and scope

Authoritative planning baseline: `cf6030ad70f862ae41c2154270040fd5e01f8285`.
On 2026-09-20, `git rev-parse HEAD main origin/main` returned that SHA for all
three references and `git status --short` was empty. No material baseline contradiction
was found. M19 design status supplied by the owner is **M19 DESIGN READY FOR PLANNING**.
The contracts below are settled implementation requirements, not alternatives.

This task creates only `docs/plans/MILESTONE-019.md`. It does not implement M19,
create V8 or ADR-022, change tests/code/frontend/OpenAPI/Compose/CI, commit, or push.
All paths and classes described below are future implementation work unless explicitly
identified as existing. Implementation must recheck the baseline and stop on concrete
contradictions rather than silently adapting the security design. Intermediate slices
are not deployable releases; external exposure is permitted only after closure gates.

## Purpose and verified starting state

Operators sign in through an external OIDC provider and a backend-managed browser
session. API/CI callers present validated access tokens. Both produce one canonical
application principal with explicit permissions. Reads, acknowledgement, and manual
lifecycle evaluation have separate permissions; scheduling remains trusted in-process
work. New ACK facts have durable authenticated attribution, while old caller assertions
remain explicitly legacy. This is not an identity-management or generic audit product.

Repository evidence inspected at the baseline:

| Existing location | Verified starting fact / implementation consequence |
| --- | --- |
| `backend/pom.xml` | Java 21, Spring Boot 3.5.7, web/actuator/JDBC/H2/Flyway; no OAuth starters. Preserve Boot version. PMD, SpotBugs/Find Security Bugs run at verify. |
| `backend/src/test/java/io/geordi/architecture/ArchitectureTest.java` | Core is framework-independent; bootstrap cannot depend on concrete optional modules. Add rules without weakening existing rules. |
| `docs/api/openapi.yaml` and application controllers | OpenAPI 3.1.0, 23 operations, no application authentication. Header currently says milestone-17; M19 reconciles it with the actual contract. |
| `backend/src/main/resources/db/migration/` | Latest migration is `V7__create_alert_notification_disposition.sql`; no V8. M18 changed durable JSON compatibility, not schema version. |
| `alerts/application/AcknowledgeAlertEpisodeService.java` | Actor is caller supplied; actor and reason use `String.strip()`, empty reason becomes null, reason maximum is 512 code points. |
| `alerts/domain/AlertEpisodeAcknowledgement.java` | Existing fact contains episode ID, actor, reason, timestamp; actor maximum 128 code points. |
| `alerts/adapter/out/persistence/H2AlertLifecycleRepository.java` | ACK storage/read projection and episode-row serialization are existing authorities; preserve ACK/RESOLVE concurrency. |
| `alerts/adapter/spring/AlertsModuleConfiguration.java` | Current manual/scheduler lifecycle entry shares SingleFlight and observed execution. Preserve one coordinator after entry separation. |
| `frontend/src/api/client.ts`, `main.tsx`, `App.tsx` | Handwritten contracts; GET/POST helper, query retry currently 1, no auth bootstrap. |
| `frontend/src/features/alert-history/`, `features/alert-lifecycle/` | Existing ACK actor UI, detail projection and Evaluate-now are the bounded UI change points. |
| `frontend/nginx.conf`, `compose.yaml` | Current HTTP frontend proxy covers `/api/`, forwards caller Host/forwarding information, and backend is loopback-published. M19 must replace the supported ingress topology. |
| `backend/src/main/resources/application.yml` | Health exposed, readiness includes readinessState/geordiPlatform. Preserve operational semantics, constrain details and disable discovery. |
| `otel/otel-collector-config.yaml`, `backend/Dockerfile` | Basic debug exporter for traces/metrics avoids writing telemetry payload values to logs; pinned OTel Java Agent 2.28.1. Redaction after storage/export is too late. |
| `.gitlab-ci.yml`, `scripts/verify-*.ps1` | Ordered exclusive Windows Compose job, verified JAR/image provenance, 30-minute job and 27-minute script budgets. M16/M17 are embedded in history smoke; preserve those assertions. |
| `docs/plans/MILESTONE-018.md`, `docs/product/PRD.md`, `ROADMAP.md` | M1–M18 complete; owner-authoritative M18 integration approximately 24m36s, backend 438 tests. Historical evidence, not rerun in this planning task. |

Java paths abbreviated to `alerts/...` above are relative to
`backend/src/main/java/io/geordi/`. Relevant existing architecture/operations documents
are `MODULES.md`, `ALERT_LIFECYCLE.md`, `SELF_OBSERVABILITY.md` under
`docs/architecture/`, and `deploy/README.md`.

## Architecture and trust boundaries

```text
browser -> OIDC code + PKCE -> validated identity -> bounded server session --+
API/CI  -> RFC 9068 resource-server validation -----------------------------+-> canonical principal
canonical principal -> HTTP policy -> authorized application command -> existing domain
scheduler -> trusted internal application entry -> shared lifecycle coordinator
```

Pure contracts belong to `io.geordi.core.application.security`: `PrincipalIdentity`,
`AuthenticatedPrincipal`, `GeordiPermission`, `AuthenticationMechanism`, and a small
permission-checking service/exception if needed. No Spring, servlet, `Jwt`, `OAuth2User`,
OIDC/provider, JSON, HTTP-client, or OTel SDK types enter these contracts or domain.
Use `io.geordi.bootstrap.security` for protocol/configuration adapters and composition
that depend only on core contracts, never on concrete Alerts classes. Alerts composition
stays in `alerts.adapter.spring.AlertsModuleConfiguration`. Security observation adapters
may live under `selfobservability.adapter`; preserve core/bootstrap independence rules.
If that placement is used, expose a pure observation port in core and inject it into
bootstrap security adapters; never import self-observability implementations into bootstrap.

Alerts application translates canonical issuer/subject/display name into an Alerts-owned
attribution value before domain/persistence calls. Alerts domain cannot depend on core
security. HTTP controllers may depend only on external authorized mutation interfaces,
not the internal lifecycle entry, coordinator, raw mutation services or repository ports.
Scheduler may depend only on the trusted lifecycle entry. No header, request field,
principal mechanism, role or route can select internal authority. ArchUnit and Spring
wiring tests prove these restrictions, including transitive delegate wiring.

Suggested composition:

```text
AuthorizedAcknowledgeAlertEpisodeUseCase(principal, episodeId, reason)
  -> permission check -> Alerts attribution -> shared ACK service/repository
AuthorizedManualLifecycleEvaluationUseCase(principal, policyId)
  -> permission check -> shared SingleFlight(observed lifecycle service)
TrustedInternalLifecycleEvaluationUseCase(policyId)
  -> same shared SingleFlight(observed lifecycle service)
```

The old credential-free lifecycle interface must not remain injectable into web code.
Keep the common executor out of controller injection; use explicit bean qualifiers/types
and a context test to prevent accidental bypass. Do not duplicate lifecycle logic or
create a fake scheduler principal. Mutation authorization is a pure application check,
not merely a controller annotation or Spring authority check.

## Canonical identity, permissions and mapping

`AuthenticatedPrincipal` has `PrincipalIdentity identity`, nullable `String displayName`,
an immutable `Set<GeordiPermission> permissions`, and mechanism `SESSION` or `BEARER`.
Identity equality is exactly issuer + subject. Do not normalize those strings after
validation, and never use email/name/grant/scope/Spring authority as identity.

| Value | Frozen validation |
| --- | --- |
| issuer | Absolute HTTPS URI, at most 2048 ASCII characters, no credentials/query/fragment; exact comparison, no URI normalization. |
| subject | 1..255 printable ASCII characters, not whitespace-only. |
| displayName | Optional; at most 128 Unicode scalar values, no controls; empty, invalid, unpaired surrogate or excessive value becomes null. |

| Permission | Public spelling | Bundle membership |
| --- | --- | --- |
| `OBSERVABILITY_READ` | `observability:read` | VIEWER, OPERATOR, EVALUATOR |
| `ALERT_ACKNOWLEDGE` | `alerts:acknowledge` | OPERATOR |
| `ALERT_EVALUATE` | `alerts:evaluate` | EVALUATOR |

Bundles are deployment configuration conveniences only. Exactly these permissions:
no ADMIN, wildcard, CONFIGURATION_ADMIN or implicit read grant from mutation permission.
Test a principal with only each mutation permission, not only bundled identities.

Provider-neutral configuration under `geordi.security` names issuer, API audience,
browser client ID/secret reference, public-base-url, one top-level grant claim and an
explicit external-value-to-permissions map. API audience differs from browser client ID.
The grant claim must be an array of at most 100 strings, each at most 128 Unicode scalar
values; malformed shape rejects authentication. Absent claim gives zero permissions;
unknown value grants nothing. Session mapping uses validated ID-token claims, bearer
mapping uses validated access-token claims. Never merge scopes, scp, roles, groups or
Spring authorities. Invalid mapping/configuration fails startup; no disabled-auth mode.
Secrets use mounted/runtime secret input and never configuration dumps or command echo.

## Complete HTTP operation policy

All 23 existing application operations are enumerated below. R = OBSERVABILITY_READ,
A = ALERT_ACKNOWLEDGE, E = ALERT_EVALUATE. Both valid mechanisms are accepted unless
otherwise specified. Every GET in this table also allows HEAD with identical security,
status and headers but no body. HEAD never executes a mutation.

| # | Method | Existing path | Permission |
| --- | --- | --- | --- |
| 1 | GET | `/api/platform` | R |
| 2 | GET | `/api/modules` | R |
| 3 | GET | `/api/platform/health` | R |
| 4 | GET | `/api/metrics/services` | R |
| 5 | GET | `/api/metrics/overview` | R |
| 6 | GET | `/api/metrics/series` | R |
| 7 | GET | `/api/traces/services` | R |
| 8 | GET | `/api/traces` | R |
| 9 | GET | `/api/traces/{traceId}` | R |
| 10 | GET | `/api/logs/services` | R |
| 11 | GET | `/api/logs` | R |
| 12 | GET | `/api/service-map` | R |
| 13 | GET | `/api/slos` | R |
| 14 | GET | `/api/slos/{sloId}` | R |
| 15 | GET | `/api/slos/{sloId}/evaluation` | R |
| 16 | GET | `/api/alert-policies` | R |
| 17 | GET | `/api/alert-policies/{policyId}/evaluation` | R |
| 18 | POST | `/api/alert-policies/{policyId}/lifecycle-evaluations` | E |
| 19 | GET | `/api/alert-states` | R |
| 20 | GET | `/api/alert-episodes` | R |
| 21 | GET | `/api/alert-episodes/{episodeId}` | R |
| 22 | POST | `/api/alert-episodes/{episodeId}/acknowledgements` | A |
| 23 | GET | `/api/alert-transitions` | R |

| Additional route | Exact allowed method / policy |
| --- | --- |
| `/api/me` | GET/HEAD; authentication only, zero permissions allowed. |
| `/api/auth/csrf` | GET only; authenticated SESSION, no extra permission. |
| `/api/auth/logout` | POST only; authenticated SESSION + CSRF. |
| `/actuator/health/liveness`, `/actuator/health/readiness` | GET/HEAD anonymous, status-only response. |
| `/actuator/health` | GET/HEAD, authenticated + R. |
| `/oauth2/authorization/geordi` | GET only, anonymous login initiation with bounded admission. |
| `/login/oauth2/code/geordi` | GET only, anonymous protocol callback with mandatory transaction validation. |
| SPA shell and built assets | Explicit GET/HEAD frontend route/asset allowlist; no catch-all API/protocol/management fallback. |
| Everything else, including unlisted methods | Deny; no handler or state mutation. |

No broad `/api/**`, `/actuator/health/**` or `/error` permitAll. Disable actuator discovery
and expose no other management endpoints. Error dispatch must render a bounded response
without granting a new request access to `/error`. Test normal/error/forward dispatch,
path normalization, trailing slash, encoded separators, TRACE/OPTIONS/PUT/PATCH/DELETE
and POST-to-read paths. Authenticated denied requests return bounded 403; absent/invalid
authentication on protected routes returns 401. Unsupported protocol methods are denied,
not silently handled as GET. Do not redirect API 401 to login.

Liveness/readiness do not acquire transient IdP reachability contributors. Existing
platform readiness semantics remain; exact anonymous probe responses reveal only status.
Explicit management detail policy must not leak component details on probe subpaths.

## Credential selection and request ordering

Before operation execution, inspect raw credential multiplicity (including what nginx
coalesces), then resolve existing session without creating one:

1. Duplicate/coalesced/multiple Authorization credentials: 400.
2. Duplicate `__Host-GEORDISESSION` cookies: 400, including duplicate equal values.
3. Valid authenticated session plus any Authorization header: 400.
4. Authorization present without authenticated session: bearer authentication only;
   unsupported/malformed scheme is 401. Never fall back after invalid bearer.
5. Authorization absent: use valid session if present, otherwise unauthenticated.
6. Expired/unknown session cookie does not block a valid bearer. Never merge identities
   or permissions. A prelogin session is not an authenticated session.

Test actual multiple headers and raw Cookie fields over the nginx/backend path, not only
MockMvc. Do not trust a proxy header claiming authentication or precomputed principal.
CSRF/logout reject a valid BEARER principal with 403.

Processing order is credential syntax -> authentication -> route permission -> session
CSRF -> deserialization/validation -> resource lookup -> command authorization + command.
Application authorization checks precede repository/lookup side effects even when called
directly. Invalid ACK body or unknown episode must not reveal application information
to unauthorized users. Filter ordering must return missing/expired session 401 before
CSRF 403, and missing permission before body validation. Test each competing failure.

## JWT and trusted remote metadata contracts

RFC 9068 access-token adapter requirements:

- Compact signed JWS only; RS256 only, RSA >=2048 bits; `typ` is `at+jwt` or
  `application/at+jwt`; exact configured issuer and configured API audience.
- Required `iss`, `sub`, `aud`, `exp`, `iat`, `client_id`, `jti`; validate `nbf` if present.
  Use 60-second clock skew; `exp > iat`, declared lifetime <=1 hour. Validate claim
  types and time relationships, including future issued-at beyond skew.
- Required `kid`, nonempty and at most 128 characters. `client_id` and `jti` are nonempty
  printable strings <=255. Token <=16 KiB before parsing/remote work.
- Reject none, HMAC, JWE, unknown critical JOSE members, duplicate JSON members in
  header/payload, token-selected key URLs, wrong token purpose and ID tokens presented
  to API even if otherwise signed by a trusted key. Keys come only from trusted metadata.
- JOSE details stay in adapter tests. Do not assume default Spring/Nimbus validation
  proves this profile; configure/extend bounded parsing and validators explicitly.

Discovery/JWKS use HTTPS with certificate validation, no redirects, 2-second connect
and 5-second total operation timeout. Discovery <=64 KiB; JWKS <=256 KiB, <=32 keys,
unique kid, valid usable signing key material. Validate metadata issuer exactly and
trusted HTTPS endpoints; never derive discovery from untrusted token issuer. Enforce
response bounds while streaming, not after unbounded buffering.

Startup requires valid configuration, discovery and usable trusted keys. Normal JWKS
refresh every 5 minutes; maximum usable set age 15 minutes from last successful fetch,
not last failed attempt. Unknown-kid refresh at most once per 30 seconds, coalesced
across concurrent requests. Successful refresh atomically replaces the prior set;
removed keys cannot resurrect from per-key/decoder caches. If a trusted cached key is
still usable, validate locally during outage. Unknown key after successful refresh is
401. Dependency unavailable with no usable trusted key is 503. Invalid token remains
401 when invalidity is independently established; outage never permits authentication.
Use injected time/concurrent tests, not real five-/fifteen-minute sleeps.

## OIDC, session, origin and CSRF contracts

Browser login is confidential-client authorization code using `client_secret_basic`,
mandatory PKCE S256, state, nonce, single-use transaction with five-minute lifetime,
`response_mode=query`, and exact callback `{public-base-url}/login/oauth2/code/geordi`.
Validate ID-token signature, issuer, audience, azp, times and nonce; reject callback
replay, missing/mismatched/expired transaction, code substitution and token endpoint
failure. Do not apply access-token typ requirements to legitimate OIDC ID tokens.
No UserInfo or offline_access. On success rotate session ID and redirect only to `/`.
Disable arbitrary saved requests and returnUrl. Consume transaction atomically.

After principal construction, discard access/refresh/ID tokens and raw claim set; do not
retain `OidcUser` or token-bearing authorized-client state in SecurityContext, session,
repository, request cache or completion handlers. Retain only canonical principal and
bounded session metadata. Test reachable session/authorized-client state and failure
cleanup, not only the response DTO. Transient code/verifier/state/nonce exist only for
the bounded transaction and are removed on consumption/expiry.

Server-side in-memory single-node sessions use exactly `__Host-GEORDISESSION` with
Secure, HttpOnly, SameSite=Lax, Path=/ and no Domain. Idle timeout 30 minutes; absolute
timeout one hour from login, never activity-extended; restart invalidates sessions.
Admission is atomic, max 1024 total including prelogin, max 128 pending prelogin.
Cleanup every 60 seconds and before admission. No eviction of valid authenticated
sessions to accept attempts. Capacity exhaustion returns 503 + `Retry-After: 30`.
Login rotation must transfer capacity accounting atomically; callback failure/expiry,
logout and restart release resources. No implicit container-created uncounted sessions.
No Redis or SQL session store.

`public-base-url` is authoritative: HTTPS origin only, no path/query/fragment/userinfo.
Use it for callback/redirect/origin checks. Disable backend forwarded-header strategy.
nginx rejects unknown Host, strips inbound Forwarded/X-Forwarded-* and sets controlled
proxy values. Do not build security URLs from Host or forwarded headers. No trusted
identity headers. Same-origin frontend/API only; no wildcard CORS, arbitrary origin
list or cross-origin SPA support. Validate deployment/runtime API-base configuration.

CSRF is a session-bound 32-random-byte base64url synchronizer token:

```json
{"headerName":"X-CSRF-TOKEN","token":"..."}
```

GET `/api/auth/csrf` is SESSION-only, authentication-only, `Cache-Control: no-store`.
Frontend holds it only in memory. Rotate on login/session rotation and remove on logout
or expiry; new session needs new bootstrap. Valid session with missing/invalid token on
mutation is 403; missing/expired session is 401 before CSRF. Mutation Origin, if present,
must equal configured public origin. Valid bearer-only mutations are cookie-CSRF-exempt;
they still obey the Origin rule when Origin is present. Never disable CSRF globally.
Logout POST requires SESSION + CSRF, invalidates session/token, expires the same cookie,
returns 204 with no-store, and performs no IdP-wide logout or arbitrary redirect.

GET/HEAD `/api/me` returns only identity `{issuer, subject}`, nullable displayName,
permissions sorted lexicographically by public spelling, and `authMode: SESSION|BEARER`.
It requires authentication but no R permission and has no-store. No email, external
grants, raw claims, token or session identifier is returned.

## Failure, transport and observability contracts

Use RFC 9457 `application/problem+json` with fixed type/title/detail mappings and no-store.
Do not echo request target/query into problem `instance`; use an omitted instance or
fixed safe route category. Bearer 401 has a sanitized WWW-Authenticate challenge.

| Status | Bounded condition |
| --- | --- |
| 400 | Ambiguous credentials/duplicate session cookie; ACK actor or unknown property after security succeeds. |
| 401 | Missing/invalid/expired authentication; malformed bearer, signature/issuer/audience/purpose/mandatory identity failure. |
| 403 | Missing permission, failed CSRF on valid session, BEARER against SESSION-only endpoint, denied route/method for authenticated user. |
| 503 | Authenticity cannot be established due unavailable dependency; session admission exhausted (Retry-After 30). |

Configuration failure is startup failure. No security error includes token, claim set,
algorithm detail, JWKS URI, IdP exception, session ID, code, state, secret or stack trace.
Coordinated nginx/container/parser limits: JWT 16 KiB, individual header 32 KiB,
aggregate headers 64 KiB, request target 8 KiB. Oversize headers return 431, target 414,
without echoed input. Test boundary and one-byte-over via both supported ingress and
backend. A framework/proxy default returning 400 for oversize must be corrected; do not
claim that increasing a buffer alone implements separate per-field and aggregate limits.

Counters: `geordi.security.authentication.attempts` and
`geordi.security.authorization.decisions`. Dimensions are closed mechanism, result,
fixed reason and fixed endpoint category. Categories exactly: read, acknowledge,
evaluate, me, login, callback, csrf, logout, probe, denied. Define enums and exhaustive
test of allowed values; use a fixed NONE/AMBIGUOUS telemetry mechanism where no canonical
principal exists, not a new AuthenticationMechanism. Count once at the owning decision
boundary; test filters/error dispatch do not double-count. Keep platform resource tags.

Structured security logs use the same bounded event/result/reason categories without
raw exception text. Never record issuer, subject, username, email, group, jti, token,
cookie, session ID, OAuth code/state, client secret, IP, policy ID, episode ID, dynamic
path or raw exception in security logs/metric dimensions. No generic audit ledger.

Credential leak prevention is an acceptance gate before live protocol tests. Suppress
or sanitize authentication-path `url.full`, `url.query`, `http.target`, Authorization,
Cookie, Set-Cookie, bodies, token responses and credential-bearing exception messages
at the source, including agent-generated outbound token-exchange spans. Defense in
depth Collector filtering must run before detailed debug and Tempo export; verify the
pinned Collector supports any selected processor before relying on it. Do not remove
all self-telemetry or hide evidence by disabling the pipeline.

nginx access logs use safe route categories without query/headers; error logs must not
emit raw authentication request lines even on malformed/oversize requests. If nginx
cannot sanitize a diagnostic class, suppress that sensitive diagnostic source and
retain separate bounded error counters. Inspect backend/HTTP client debug logging and
framework exceptions. CI after_script currently prints Compose logs: replace this with
bounded safe diagnostics only after scanning, not raw logs followed by a late scan.

Sentinel test must inspect browser/frontend console, nginx access/error logs, backend
logs, HTTP errors, exported OTel spans/events/attributes, Collector detailed debug,
Tempo queries, CI command echo/failure diagnostics and every publishable artifact.
Use recognizable test token/code/state/cookie/secret sentinels, plus raw and encoded
forms. Scan in private ephemeral storage; report only channel/count, never matches.
Inject a harmless unique positive control into every inspected channel/pipeline; prove
expected span reaches Collector and Tempo and expected safe log reaches diagnostics.
An empty/missing capture fails. Exercise success, malformed callback, dependency failure,
401/403, duplicate credentials, oversize and CI failure cleanup paths. A deliberate
synthetic-leak negative control must prove scanner failure without publishing its input.

## ACK compatibility, migration and replay

Freeze V7 ACK fixtures and original INSERT/API examples before edits. Future migration
`backend/src/main/resources/db/migration/V8__add_authenticated_acknowledgement_attribution.sql`
adds to existing `alert_episode_acknowledgement` (created by V5, Unicode columns widened
by `V6__widen_alert_episode_acknowledgement_unicode_columns.sql`):

```sql
identity_provenance VARCHAR(32) NOT NULL DEFAULT 'LEGACY_CALLER_ASSERTED'
principal_issuer VARCHAR(2048) NULL
principal_subject VARCHAR(255) NULL
display_name_snapshot VARCHAR(256) NULL
```

Existing actor VARCHAR(256) NOT NULL, reason VARCHAR(1024) NULL, episode_id and
acknowledged_at remain unchanged. Closed provenance values are LEGACY_CALLER_ASSERTED
and AUTHENTICATED_PRINCIPAL. SQL CHECK must explicitly use IS NULL/IS NOT NULL:
authenticated requires nonnull/nonempty issuer and subject; legacy requires issuer,
subject AND snapshot null. Unknown provenance and partially populated combinations
fail. Test SQL UNKNOWN cannot accidentally satisfy the check. Domain/adapter bounds
also enforce canonical identity and <=128-scalar snapshot; verify supplementary Unicode
fits the selected H2 VARCHAR behavior without changing existing actor/reason bytes.

Old rows acquire only legacy default; no identity backfill or rewriting actor/reason/time.
Old INSERT omitting new columns yields legacy only. New writer explicitly writes
authenticated provenance. Implement dual-read before any authenticated writes; keep
frozen legacy behavior in internal compatibility tests, never expose a legacy command
over HTTP after cutover. Corrupt/unknown provenance fails boundedly, never guessed.

Alerts owns attribution variants. Existing actor remains a display projection:
valid display-name snapshot, otherwise literal `Authenticated principal`. Never join
issuer/subject into actor. Do not re-strip/normalize a valid name snapshot through the
old actor-input normalization. Response adds `attribution` with provenance, identity,
displayName. Authenticated identity is populated; legacy identity/displayName are null
and actor is unchanged. API types do not reveal SQL column names/layout.

ACK request is `{ "reason": "..." }` or `{}`; reason remains optional/nullable.
Any actor presence including null and any unknown property yields 400 only after
security checks. Use a strict ACK request decoder/DTO; do not globally change unrelated
JSON compatibility. Preserve reason strip, empty->null, maximum 512 code points.

| Persisted state / command | Outcome |
| --- | --- |
| Open episode, no ACK | 201 new authenticated fact |
| Same issuer+subject, same normalized reason | 200 original fact |
| Same subject, different issuer | 409 |
| Different identity or normalized reason | 409 |
| Only display name changed | 200 original timestamp and original name/actor snapshot |
| Existing legacy ACK, any authenticated command | 409; never claim/upgrade by actor matching |
| Closed episode, even exact replay | 409 |

Preserve one ACK per episode, episode-row locking, ACK/RESOLVE serialization and all
M10–M18 lifecycle/history/outbox/routing/evidence semantics. Restart must retain new
attribution and old legacy rows. ACK changes no delivery or lifecycle authority.

## Dependency-ordered implementation slices

For each slice write meaningful behavioral/architecture tests first (RED/GREEN), or
alongside adapter configuration when test-first is impractical. Proposed test paths are
specified in the test matrix below. Do not mark a slice accepted merely because it
compiles. Stop conditions are gates, not permission to omit remaining work.
Test-category references in early slices mean the applicable foundation subset;
later slices complete their integration coverage. Final full-matrix acceptance is
explicitly assigned to Slice 9 and full pipeline/CI proof to Slices 11–12.

### Slice 0 — Freeze baseline and compatibility evidence

- Purpose/contracts: record actual V7 legacy facts, API shape and concurrency before
  changing ACK types; all existing M9–M18 semantics remain authoritative.
- Files: proposed `backend/src/test/resources/io/geordi/alerts/adapter/out/persistence/compatibility/ack-v7.sql`
  and `ack-v7-api.json`; existing service/domain/repository/controller tests and this plan.
- Steps: recheck refs/status, inventory migrations/23 routes/bean graph; freeze original
  INSERT and Unicode/null reason/time fixtures from baseline, record baseline gates.
- Tests: legacy roundtrip, normalization and ACK/RESOLVE tests; test matrix 16–18.
- Depends on: none. Accept when frozen evidence passes on baseline and provenance is
  recorded. Stop on contradictory schema/API/authority; do not regenerate fixtures from
  changed M19 models or silently bless their output.

### Slice 1 — Canonical application contracts and ownership

- Purpose/contracts: immutable identity/principal/permission values and Alerts attribution
  variants; application permission checks; no protocol types in pure layers.
- Files: new `core/application/security/*`, `alerts/domain/AlertAcknowledgementAttribution.java`,
  existing `AlertEpisodeAcknowledgement.java`; `architecture/ArchitectureTest.java`.
- Steps: implement bounds/equality and explicit permission mapping targets; add Alerts
  attribution without making existing legacy constructors falsely authenticated.
- Tests: matrix 1, 3, 4, 17, boundary Unicode/equality and immutable permission set tests.
- Depends on: 0. Accept when pure tests and existing domain regressions pass. Stop if
  domain needs Spring/core-security/provider types or permissions are inferred.

### Slice 2 — Additive V8 and dual-read ACK repository

- Purpose/contracts: safe additive storage before writer cutover.
- Files: future V8 migration; `alerts/application/port/out/AlertEpisodeAcknowledgementRepository.java`,
  `alerts/adapter/out/persistence/H2AlertLifecycleRepository.java`, acknowledgement domain
  and history snapshot/projection as needed for dual-read; update forwarding signatures
  in `alerts/adapter/out/telemetry/ObservedAcknowledgeAlertEpisodeUseCase.java` and
  `ObservedAlertHistoryRepository.java` together; frozen fixtures stay unchanged.
- Steps: migrate, map both provenances explicitly, add internal authenticated write
  capability only once reader exists; keep public writer legacy until secure cutover.
  Introduce new signatures without deleting compatibility proof.
- Tests: matrix 16–18; empty/V7/older chain, old INSERT, constraint truth table, restart,
  Unicode, one-per-episode and ACK/RESOLVE races. Run existing migration tests too.
- Depends on: 0–1. Accept when mixed stored data is correctly readable and old rows are
  byte/semantic-preserved. Stop on any misclassification or lost serialization. No
  intermediate binary may be exposed as an authenticated M19 release.

### Slice 3 — Configuration, dependencies and early safe telemetry

- Purpose/contracts: validated `geordi.security`, fail-closed startup and safe instrumentation
  before any sentinel or token-bearing integration traffic.
- Files: future `bootstrap/security/SecurityProperties.java`, configuration validators,
  `backend/pom.xml`, `application.yml`, self-observability adapters/configuration,
  `otel/otel-collector-config.yaml`, `frontend/nginx.conf`, CI diagnostic helpers as needed.
- Steps: evaluate OAuth2 client/resource-server starters and test-scoped security-test;
  inspect transitive graph, do not explicitly add starter-security without necessity.
  Keep Boot unchanged. Define bounded error enums and source-side leak suppression;
  document secret input and strict startup validation; prepare tests with real configuration.
- Tests: matrix 2, 4, 22–23, configuration invalidity, telemetry positive/negative controls.
- Depends on: 1. Accept when secrets cannot enter default diagnostics and config rejects
  unsafe values. Stop on hidden auth bypass flags, trust-all SSL or unbounded exceptions.

### Slice 4 — Dedicated test IdP and local TLS foundations

- Purpose/contracts: one lightweight fixture reused by backend integration and Compose,
  excluded from production artifact; trusted TLS transport, no CI bypass.
- Files: proposed `deploy/oidc-fixture/`, `scripts/New-GeordiTestTls.ps1`,
  `scripts/lib/GeordiAuthentication.ps1`, `compose.m19.yaml`, base Compose/nginx and
  deployment environment examples; test-only browser harness under `frontend/e2e/`.
- Steps: implement discovery, JWKS, RSA signing, distinct access/ID tokens, code flow,
  exact redirects, client_secret_basic, S256, nonce, state roundtrip/binding, one-use
  code and invalid-claim/rotation/outage controls on test-only private control channel.
  Generate ephemeral CA/certs with deterministic names/SANs/trust setup (random keys,
  not committed fixed private material). nginx serves geordi.localhost and fixture TLS
  auth.localhost; backend resolves auth.localhost over Compose DNS with matching SAN.
  Resolve frontend/backend dependency cycle by starting TLS/fixture before backend
  discovery; nginx must tolerate backend startup without depending on backend health.
- Tests: TLS hostname/cert rejection, discovery/code fixture tests, startup-order proof;
  fixture endpoints cannot be packaged or exposed in production backend.
- Depends on: 3. Accept when browser, Java trust store and PowerShell CI explicitly trust
  generated CA without ignore flags, fixture controls are isolated, secrets stay outside
  artifacts, and cleanup removes temporary private material/trust additions on failure.
  Stop if private keys/credential URLs appear in command arguments/logs or HTTP bypass
  is needed. Defer full semantic smoke until later slices.

### Slice 5 — Bearer/discovery/JWKS adapter

- Purpose/contracts: strict RFC 9068 identity and explicit grant mapping, trusted metadata
  cache/outage behavior defined above.
- Files: proposed `bootstrap/security/jwt/*`, `bootstrap/security/metadata/*`,
  `bootstrap/security/ExternalGrantMapper.java`; test fixture support.
- Steps: bounded parse/profile validators, trusted TLS fetches, atomic replace cache,
  refresh coalescing and local-cache decisions, sanitized failures; canonical conversion.
- Tests: matrix 2, 5–7, all JWT negative cases and virtual-clock/concurrency JWKS cases.
- Depends on: 1, 3–4. Accept when no default decoder shortcut admits ID tokens/stale or
  removed keys and startup requires keys. Stop on authenticity ambiguity or fail-open.

### Slice 6 — Browser OIDC and bounded sessions

- Purpose/contracts: code+PKCE login yields only canonical principal; session lifetime,
  fixation, capacity and credential disposal meet the frozen model.
- Files: proposed `bootstrap/security/oidc/*`, `bootstrap/security/session/*` and tests.
- Steps: enforce transaction/ID token checks; use exact callback/redirect; replace default
  token-bearing state; bounded atomic session admission/rotation/cleanup; cookie policy.
- Tests: matrix 8–9, retained-state traversal, nonce/state/code replay, parallel admission,
  fixation, idle versus absolute clock tests, restart and callback-failure cleanup.
- Depends on: 1, 3–5. Accept when no post-login tokens/raw claims remain and concurrent
  limits hold. Stop on uncounted session allocation or retained authorized-client state.

### Slice 7 — Default-deny ingress and application entry separation

- Purpose/contracts: credential selection, route matrix, error/transport contract plus
  independent application mutation guards and trusted scheduler entry.
- Files: `bootstrap/security/*` filters/chain/problems, all existing web controllers
  for principal adaptation only, `alerts/application/Authorized*UseCase.java`, trusted
  lifecycle entry, `AlertsModuleConfiguration.java`, `AlertEvaluationScheduler.java`.
- Steps: implement exact path+method rules, authenticated read gates, probe policy,
  ambiguity checks before authentication and CSRF; split entries over one existing
  SingleFlight coordinator; wire controllers to authorized interfaces. ACK remains
  non-public during this integration slice until Slice 8 atomically switches the DTO
  and authenticated write path. No temporary permitted actor-input route.
- Tests: matrix 3–4, 7, 11–13, 19–20, real nginx duplicate credentials and direct wrapper
  invocation without permission; ensure both entries share overlap prevention.
- Depends on: 2, 5–6. Provisional acceptance requires implemented read/manual/probe/login
  route tests plus structural/wiring tests, and proof that ACK and unimplemented
  me/CSRF/logout routes remain denied. Do not require their future success cases here.
  The complete matrix is the combined 7–9 gate at the end of Slice 9. Stop if
  HTTP can reach internal/raw mutation, scheduler needs credentials, or security order
  allows body/resource leakage. This slice and 8–9 form one externally releasable unit.

### Slice 8 — Authenticated ACK public cutover and API contract

- Purpose/contracts: reason-only ACK, authenticated attribution, frozen replay table and
  consistent read projection; no caller actor path survives.
- Files: `AcknowledgeAlertEpisodeService.java`, authorized wrapper, ACK controller/request
  and DTO mappers in `alerts/adapter/in/web/AlertHistoryController.java`, history query
  snapshot types and `docs/api/openapi.yaml`.
- Steps: strictly reject actor presence/unknown fields after security; derive attribution
  solely from canonical principal; preserve normalized reason; enable authenticated
  writer and dual-read projection together; update status/response schemas.
- Tests: matrix 15–18, malformed unauthorized bodies, same-subject/different-issuer,
  changed name, legacy conflict, closed replay, persistence restart and concurrency.
- Depends on: 2, 7. Accept when all public new writes explicitly authenticated and legacy
  reads unchanged except additive attribution. Stop if actor matching upgrades legacy,
  a new fact is unreadable or shared lifecycle semantics change.

### Slice 9 — Me, CSRF and logout protocol

- Purpose/contracts: canonical bootstrap and session-only synchronizer-token lifecycle.
- Files: proposed `bootstrap/security/api/IdentityController.java`, CSRF/logout adapters,
  session code and OpenAPI protocol paths.
- Steps: implement me/no-store/sorted permissions; session-token bootstrap and rotation;
  enforce Origin/mutation order, logout invalidation/204, no credential-bearing responses.
- Tests: matrix 10, 14, ordering/expiry, bearer 403, zero-permission me, HEAD body absence.
- Depends on: 6–8. Accept when session mutations cannot proceed without valid CSRF and
  unauthenticated requests get 401 first. Stop on globally disabled CSRF or token reuse
  across sessions. Complete and pass the entire route matrix with the now-implemented
  authenticated ACK and real protocol endpoints; this is final acceptance of the
  combined Slices 7–9 unit, before frontend/semantic-smoke work proceeds.

### Slice 10 — Frontend bounded auth and permission UX

- Purpose/contracts: bootstrap before protected queries, canonical permission context,
  reason-only ACK and truthful legacy/authenticated display.
- Files: `frontend/src/main.tsx`, `App.tsx`, `components/AppShell.tsx`, `api/client.ts`,
  `api/types.ts`, `api/alertHistory.ts`, new `features/auth/*`, `api/auth.ts`, existing
  alert-history input/detail/tests and alert-lifecycle page/hooks/tests.
- Steps: login-required/forbidden states, login navigation, me then CSRF for sessions,
  in-memory token, logout; no permission inference from bundles; gate read queries by R,
  ACK by A, Evaluate-now by E. Remove actor input. Set 401/403 as non-provider/nonretry
  errors; do not automatically replay a mutation after login or CSRF renewal.
  Abort/ignore old principal requests using auth generation and clear TanStack Query
  caches on logout/principal change, including late responses and mutation state.
- Tests: matrix 21, delayed completion after logout/switch, zero-permission me, mutation-only
  principal, forbidden versus login-required, old ACK rendering, empty/new CSRF state.
- Depends on: 8–9. Accept when no protected query starts before auth/permission readiness
  and stale data cannot reappear. Stop on token persistence in storage or UI-only auth.

### Slice 11 — Complete telemetry, ingress and leak proof

- Purpose/contracts: end-to-end bounded observability and transport, with positive controls.
- Files: self-observability security adapters/tests, nginx/agent/Collector configuration,
  proposed `scripts/Test-GeordiCredentialLeaks.ps1`, `frontend/e2e/security.spec.ts`.
- Steps: finish counters/logs and all capture/scanner paths; test source redaction and
  Collector defense before exporters, nginx malformed/error logging, header/target
  bounds, Host/forwarded spoofing. Include downstream token client spans and failure paths.
- Tests: matrix 11–13, 22–23; sentinel controls in each channel including artifact staging.
- Depends on: 3–10. Accept only with active pipeline proof and zero leaks. Stop on any
  leak, missing capture or diagnostic artifact retaining credentials; remediate at source.

### Slice 12 — Authenticated semantic chain and CI budget evidence

- Purpose/contracts: one M19 smoke plus the complete existing ordered regressions, using
  shared credentials and one real browser login proof.
- Files: proposed `scripts/verify-security.ps1`, shared auth/TLS/leak helpers, existing
  `scripts/verify-*.ps1`, `.gitlab-ci.yml`, Compose files and test-only browser dependencies.
- Steps: implement sequence below; convert application requests to shared authenticated
  helpers, including parallel runspaces and backend/proxy calls; adapt M16 actor expectations
  deliberately, keep legacy coverage in migration tests; preserve M17/M18 semantic coverage,
  artifact provenance, cleanup and bounded diagnostics. Keep demo/provider probes distinct.
- Tests: matrix 23–25, script credential renewal without command replay, no fallback to
  anonymous, clean checkout candidate/JAR/image identity, failure cleanup exercise.
- Depends on: all runtime slices. Accept when timing ledger, complete chain and leak
  gates pass inside measured budget. Stop on skipped semantics, duplicate expensive
  provider scenarios or timeout increase without measurements and documented rationale.

### Slice 13 — ADR and documentation reconciliation

- Purpose/contracts: truthful reproducible operator/deployment/API/rollback documentation.
- Files: `README.md`, `docs/product/PRD.md`, `ROADMAP.md`, `docs/architecture/MODULES.md`,
  `ALERT_LIFECYCLE.md` (including acknowledgement/history sections), `SELF_OBSERVABILITY.md`,
  `deploy/README.md`, proposed `docs/architecture/SECURITY.md`, `docs/api/openapi.yaml`,
  future `docs/adr/ADR-022-external-identity-adapters-application-authorization-and-authenticated-alert-attribution.md`,
  this plan's implementation evidence record.
- Steps: document exact title **External Identity Adapters, Application Authorization,
  and Authenticated Alert Attribution**, configuration/trust setup, no credentials in
  examples, permissions, actor break, legacy meaning, session restart and rollback.
- Tests: OpenAPI validation and documentation-to-route/config checks (matrix 24).
- Depends on: runtime/contract shape established; maintain relevant docs alongside edits,
  final reconcile after 12. Accept when startup instructions are reproducible and no
  planned feature is claimed implemented without evidence. Stop on stale anonymous examples.

### Slice 14 — Independent implementation review and closure

- Purpose/contracts: verify all completion criteria and a fresh independent final diff.
- Files: only fixes justified by review; this plan closure evidence.
- Steps: run full gates below, review artifact/runtime provenance, configured reviewer
  read-only inspection, resolve all findings, re-run affected tests, inspect final diff.
- Tests: full backend/frontend/contracts/runtime gates, not a compile-only declaration.
- Depends on: 0–13. Accept when evidence is recorded and independent findings resolved.
  Stop on any missing evidence, regression, leak or scope expansion; record out-of-scope
  findings as debt rather than implementing M20 features.

## Concrete test matrix

Java test locations below are relative to `backend/src/test/java/io/geordi/`.
New classes are proposed; existing classes must be extended without discarding old
semantic coverage. Fast suites use real security filters with signed fixture tokens;
mock users alone cannot prove adapter authentication. Integration tests named
`*IntegrationTest` must actually execute under the existing Maven test lifecycle.

| # | Category | Files / required proof |
| --- | --- | --- |
| 1 | Canonical values | `core/application/security/AuthenticatedPrincipalTest.java`, `PrincipalIdentityTest.java`, `GeordiPermissionTest.java`: bounds, exact identity, immutable grants, no implied permission. |
| 2 | Claim mapping | `bootstrap/security/ExternalGrantMapperTest.java`, `SecurityPropertiesTest.java`: missing/unknown/malformed/bounds, startup rejection, no merged grants. |
| 3 | Application guards | `alerts/application/AuthorizedAcknowledgeAlertEpisodeUseCaseTest.java`, `AuthorizedManualLifecycleEvaluationUseCaseTest.java`: unauthorized direct calls never delegate/lookup. |
| 4 | ArchUnit/wiring | `architecture/ArchitectureTest.java`, proposed `bootstrap/security/SecurityWiringIntegrationTest.java`: pure layers, Alerts-owned attribution, no HTTP/internal/raw entry access, shared coordinator. |
| 5 | JWT profile | `bootstrap/security/jwt/AccessTokenProfileTest.java`, `BearerAuthenticationIntegrationTest.java`: every required/forbidden JOSE/claim/length/time case with signed tokens. |
| 6 | JWKS | `bootstrap/security/metadata/TrustedJwksCacheTest.java`, `OidcMetadataClientTest.java`: TLS/redirect/size/time bounds, duplicate kids, replacement, removal, outage/status, refresh herd and age. |
| 7 | Ambiguity | `bootstrap/security/CredentialSelectionIntegrationTest.java`, `scripts/verify-security.ps1`: raw duplicate/coalesced headers/cookies, mixed valid session, stale cookie+bearer through nginx. |
| 8 | Browser OIDC | `bootstrap/security/oidc/OidcLoginIntegrationTest.java`, `frontend/e2e/security.spec.ts`: PKCE/confidential client/state/nonce/azp/replay, credential disposal, exact callback. |
| 9 | Session | `bootstrap/security/session/BoundedSessionStoreTest.java`, `SessionLifecycleIntegrationTest.java`: atomic capacity/prelogin, rotation/fixation, cleanup, idle/absolute/restart. |
| 10 | CSRF | `bootstrap/security/CsrfIntegrationTest.java`: 32-byte token, memory/session binding, rotation, ordering, Origin, bearer exemption and protocol denial, logout. |
| 11 | Origin/proxy | `bootstrap/security/PublicOriginTest.java`, real proxy scenarios in `verify-security.ps1`: unknown Host/forwarding injection, safe redirects, limits and method normalization. |
| 12 | Route matrix | `bootstrap/security/RoutePermissionMatrixIntegrationTest.java`: all 23 operations + protocol paths, GET/HEAD, no/each permission and both mechanisms, unlisted methods/paths/dispatch. |
| 13 | Actuator | `bootstrap/security/ManagementSecurityIntegrationTest.java`: exact anonymous status-only probes, authenticated detailed health, discovery/subpaths denied, IdP outage no new readiness coupling. |
| 14 | Me | `bootstrap/security/api/IdentityControllerIntegrationTest.java`: zero grants, sorted output, no-store, HEAD, no raw claims/credentials. |
| 15 | ACK request | Existing `alerts/adapter/in/web/AlertHistoryControllerTest.java` plus security integration: actor null/value/unknown field denied after auth, reason normalization, resource privacy order. |
| 16 | ACK migration | New `alerts/adapter/out/persistence/AlertAcknowledgementV8MigrationIntegrationTest.java`: empty->V8, populated V7->V8, older full chain->V8, old INSERT default, valid/invalid combinations, Unicode, restart. |
| 17 | Replay/provenance | Existing `alerts/domain/AlertEpisodeAcknowledgementTest.java`, `alerts/application/AcknowledgeAlertEpisodeServiceTest.java`, `H2AlertLifecycleRepositoryTest.java`: all replay rows, frozen legacy display/snapshots. |
| 18 | Concurrency | Existing `alerts/adapter/out/persistence/H2AlertLifecycleRepositoryTest.java`: barrier-controlled ACK-first/RESOLVE-first, competing ACKs, one immutable row; same serialization as baseline. |
| 19 | Manual permission | Existing `alerts/adapter/in/web/AlertLifecycleControllerTest.java` plus authorized wrapper tests: E only succeeds, OPERATOR fails, no implicit R. |
| 20 | Scheduler regression | Existing `alerts/adapter/in/worker/AlertEvaluationSchedulerTest.java`, `alerts/application/SingleFlightAlertLifecycleEvaluationUseCaseTest.java`: credential-free internal path, shared overlap protection, existing queue/cadence/shutdown. |
| 21 | Frontend | New `frontend/src/features/auth/AuthProvider.test.tsx`; extend `App.test.tsx`, `api/client.test.ts`, alert-history/lifecycle tests: bootstrap, permissions, no automatic replay, stale-query/cache isolation, attribution. |
| 22 | Security telemetry | New `selfobservability/adapter/security/SecurityObservationTest.java`: exact counters/dimensions, bounded structured logs, no identity/cardinality, single decision counting. |
| 23 | Leak proof | New `bootstrap/security/CredentialLeakIntegrationTest.java`, browser E2E, `scripts/Test-GeordiCredentialLeaks.ps1`: full channel inventory, positive controls and scanner negative control, failure artifacts. |
| 24 | OpenAPI | Proposed `scripts/validate-openapi.mjs` (pinned test-only validator) and contract assertions in route/DTO tests: 3.1 schema, refs, security OR, permissions/errors, strict ACK, protocol endpoints. |
| 25 | M9–M18 | Full `backend/mvnw verify`, full frontend suite and existing ordered PowerShell chain; no removed persistence/evidence/provider/scheduler/history assertions. |

Freeze compatibility SQL before changing persistence; test legacy actor/reason/timestamp
and existing API projection, then assert only the intended additive attribution change.
Do not serialize updated objects to manufacture supposedly old fixture evidence.

## Exact OpenAPI implementation requirements

Keep OpenAPI 3.1. Define `bearerAuth` type http/scheme bearer/bearerFormat JWT and
`browserSession` type apiKey/in cookie/name `__Host-GEORDISESSION`. Protected operations
use OR, not both in one object:

```yaml
security:
  - bearerAuth: []
  - browserSession: []
```

Document required canonical permission per operation in description or a bounded
extension, never fake OAuth scopes. Me supports either mechanism; csrf/logout specify
browserSession only. Document X-CSRF-TOKEN as required for session mutation, not for
bearer mutation (conditional requirement in description/test contract). Add 400 where
applicable, 401, 403 and bounded 503 plus challenge/no-store/Retry-After headers where
applicable. Preserve existing successful/domain failure responses and ACK 201/200/409.
Add me, csrf, logout (204), identity/permission/provenance schemas and attribution to
ACK response and embedded episode detail. Reason-only request has additionalProperties
false and nullable optional reason; actor presence including null invalid. Explicitly
document GET/HEAD parity for allowed read/me/probe routes; protocol csrf remains GET
only. Server examples use configured same-origin HTTPS, not obsolete localhost HTTP.
No persistence DTO/raw IdP schema. Validate spec against actual route inventory and tests.

## Semantic smoke, fixture reuse and CI budget

Existing job orders telemetry/metrics/traces/logs/service-map/SLO/burn then
`verify-alert-evaluation.ps1`, `verify-alert-lifecycle.ps1`,
`verify-notification-delivery.ps1`, `verify-alert-scheduling.ps1`,
`verify-alert-routing.ps1`, `verify-alert-history.ps1`. M16/M17 and M18 evidence already
live inside the relevant scripts; preserve their assertions, not merely their filenames.

Start TLS/fixture once before backend startup discovery. Run `verify-security.ps1` once
after stack readiness and telemetry positive controls, before the authenticated ordered
regressions. Give it isolated policy/episode fixture identities so it cannot consume
episodes required by later smokes. Restore fixture key/outage controls before regressions.
The M19 smoke proves:

1. Anonymous GET/HEAD liveness/readiness success and status-only; anonymous read 401.
2. VIEWER read success, VIEWER ACK 403; OPERATOR actor request 400 then valid reason-only
   ACK 201, durable issuer/subject/provenance correct, identical replay 200; other
   identity/reason 409; original timestamp/name snapshot retained across backend restart.
3. EVALUATOR manual lifecycle success; OPERATOR without E 403; scheduler still advances
   internally without network credentials and shares lifecycle exclusion behavior.
4. One real browser OIDC code/PKCE/session flow with trusted local CA, me, CSRF bootstrap,
   mutation failure without CSRF, success with CSRF, logout and invalidated session.
5. Invalid JWT signature, wrong audience and ID-token-as-access-token each 401.
6. Mixed/duplicate credentials through real nginx 400; unknown/expired cookie with valid
   bearer succeeds. Proxy/Host and boundary-limit checks have fixed bounded cases.
7. Sentinel inspection with positive controls across all required channels is clean.
8. Complete authenticated M9–M18 chain (and existing preceding telemetry/feature checks),
   provenance validation and cleanup. Final post-chain sentinel/artifact scan also clean.

Shared `GeordiAuthentication.ps1` obtains short-lived fixture tokens via a private
test-only mint/control channel, keeps them in process/private ephemeral storage and
attaches Authorization explicitly. Separate VIEWER/OPERATOR/EVALUATOR identities and
explicit union permission fixture for existing all-capability regression operations;
do not expand OPERATOR. Renew before expiry between operations; never retry a mutation
automatically on auth failure. Pass tokens privately to parallel runspaces, never CLI
arguments/stdout/URLs. Reuse helper/bootstrap across Compose overlay restarts and ensure
each overlay retains security configuration/trust; fail if auth settings disappear.
Do not perform full OIDC login for every script. Do not use unsigned tokens/mock auth
in Compose; backend tests may generate real signed tokens against the test issuer.

Budget: 24m36s historical integration versus 27m script leaves about 2m24s before
script limit, not a proven M19 allowance. The 30m job includes reserved teardown time.
No assumed timeout increase. Add per-stage monotonic timings (fixture/certs/build,
startup, M19, each existing smoke, scan, cleanup) and collect repeated representative
Windows runner measurements. Exhaustive JWT/claim/session/JWKS/permission permutations
belong in backend tests using injected clocks and embedded HTTPS fixture; React state
combinations belong in Vitest. Full Compose is only for nginx serialization/TLS, actual
browser flow, persistence restart, scheduler wiring and agent->Collector->Tempo/log leaks.
Share one fixture/bootstrap and reuse existing ACK restart/provider fault scenarios
where equivalent assertions can be added; preserve each old semantic outcome. Do not
parallelize stateful existing smokes or repeat costly provider-outage scenarios solely
for every role. Bound waits with conditions and explicit deadlines instead of fixed sleeps.

Before CI acceptance compare measured critical path to script and teardown budgets.
If insufficient, remove duplicated setup/scenarios while preserving coverage and measure
again. A timeout change is only a later measured implementation decision documented with
per-stage evidence and the reason coverage cannot fit safely; it is not this plan's fix.
Keep exclusive resource group, candidate checkout/JAR SHA/image labels and cleanup on
every exit. Auth fixture artifacts/private CA material must never enter build artifacts.

## Rollout, rollback and non-goals

Roll out as one coordinated single-node maintenance deployment: isolate ingress, backup
durable storage, validate issuer/audience/mapping/TLS/secret inputs and external IdP
registration, run additive V8, start the complete authenticated build, verify probes and
authenticated reads/mutations and then open supported nginx ingress. Remove direct
public backend exposure; internal container health probes remain exact status-only HTTP
on the private network, not an application authentication bypass. Document operational
sign-in recovery via validated configuration/redeployment, not emergency no-auth routes.

No schema downgrade is required. Pre-M19 binaries may structurally write legacy rows
because additive defaults permit it; that does not make them safe to expose: they remove
authentication. Mixed-version rolling deployment is unsupported. Rollback to pre-M19
requires external network isolation and preservation of upgraded data/backup; retain M18
durable v2 reader compatibility constraints as well. Never downgrade authenticated facts
to actor assertions or backfill legacy identities. Sessions are invalidated by restart.

Non-goals: local users/passwords, registration/reset, MFA implementation, IdP admin or
user directory; tenant/org model, ownership/resource ACL, ABAC, generic policy engine,
generic audit ledger, nonrepudiation/compliance claims; incidents, silences, maintenance
windows, escalation, assignment/comments, routing mutation, delivery redrive/cancel,
runtime policy/SLO CRUD; M20, Spring Boot upgrade, SCA/SBOM remediation, distributed
sessions, and general provider-storage authentication redesign. Do not add microservices
to the production modular monolith; the test IdP is a nonproduction fixture.

## Implementation completion criteria

- Full `backend/mvnw -B -ntp verify` (Windows `mvnw.cmd`) passes all tests, PMD,
  SpotBugs, Find Security Bugs and ArchUnit; record counts and tool reports.
- In frontend, `npm ci`, `npm test`, `npm run typecheck`, `npm run lint`,
  `npm run build`; real browser security E2E through supported TLS ingress passes.
- OpenAPI 3.1 validation, route/security/schema correspondence, every supported Compose
  overlay `config --quiet`, Collector/Tempo/Loki configuration validation and security
  startup validation pass. Migration compatibility and strict attribution checks pass.
- M19 semantic smoke and entire authenticated M9–M18 ordered regression chain pass,
  with verified source/JAR/image provenance, bounded runtime, successful cleanup and
  positive-controlled sentinel scan including artifacts/failure diagnostics.
- Reproducible local/CI trust and startup instructions, health/metrics/traces/structured
  logs, synchronized product/architecture/ACK/history/API/operations docs and ADR-022.
- Fresh independent implementation reviewer checks final code/diff and evidence;
  resolve findings and rerun affected gates. Planning review is not implementation proof.
  Mark M19 complete only after all acceptance evidence exists; stop at requested scope.

## Independent planning review record

The configured `reviewer` agent was requested but could not start: its fixed `gpt-5.6`
model is unavailable. As explicitly authorized, a fresh separate `gpt-6-astra` agent
performed the independent read-only fallback review against the full owner request,
this plan and relevant baseline code. The earlier repository-evidence agent was not
used as reviewer. No agent modified any repository file.

Initial findings: **BLOCKER 0 / HIGH 0 / MEDIUM 1 / LOW 0**. The MEDIUM finding was
a circular slice acceptance gate: Slice 7 required a complete route matrix before
ACK/protocol endpoints existed in Slices 8–9. Remediation gives Slice 7 provisional
implemented-route/denied-deferred-route acceptance and assigns the complete matrix to
Slice 9, with explicit dependencies on 6–8. Early foundation-test references are also
distinguished from later full integration gates. Independent remediation re-review
confirmed the fix and found **BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0** unresolved.
Accepted planning debt: none. Implementation still requires its own fresh final review.

Planning validation: complete new-file diff inspected; `git diff --check` and
`git diff --no-index --check -- /dev/null docs/plans/MILESTONE-019.md` produce no
whitespace diagnostics (the latter also checks this untracked file). HEAD, main and
origin/main remain the authoritative baseline. Final `git status --short` contains only:

```text
?? docs/plans/MILESTONE-019.md
```

No implementation/build/runtime tests were run for this planning-only change. No
production code, tests, frontend, OpenAPI, Compose, CI, V8 or ADR-022 were modified or
created. No commit or push was performed.

M19 PLANNED — READY FOR IMPLEMENTATION

## Current local execution checkpoint — 2026-09-24

Current candidate base is `2601a4ee63924e843a50dc8940a8e193709e2f5b`; the dirty
worktree at run start contained 69 modified paths and 50 new paths (119 total).
`git diff --check` passed. No GitLab, commit, push, reset, stash or discard was run.

The current fresh local run rebuilt the verified backend and dependent images, then
started the mounted M19 truststore topology. JAR, staging JAR and runtime JAR SHA-256
were `082d7a4bf40fcdc605659186421adeee3456bf39dac3efd27ec4f6f4b97b2fdf`; the
telemetry extension and its image label matched at
`44c7db976f8027437c853ad9ddb5b1a77aed50ac2104dd99a9f0106ec56582d2`. The backend
image ID was `sha256:0993165ee089bede28d4832782bdf69a860cccd9975e52926658a78aadc495c6`;
the OCI revision is the base committed HEAD for a dirty local candidate. TLS validation
and authenticated runtime preflight passed. Security smoke and real Chromium E2E passed.
Frontend tests (235), typecheck, ESLint and production build passed. PowerShell parsing,
M19 Compose validation, and cleanup self-test passed.

The ordered serial regression passed OTel (6.05s), metrics (35.11s), traces (14.45s),
logs (10.18s), service map (9.86s), and SLOs (17.87s). Burn-rate/provider recovery
failed after 181.77s: the SLO stayed BREACHED while burn remained AVAILABLE. The
dependent M9–M18 stages, live manifest completion and mandatory `Finalize` were not
run; no current-run nine-channel result, Loki/VictoriaMetrics final source query, or
credential-gate result is claimed. This run therefore does not establish the required
full serial budget or job-equivalent runtime.

Current-run strict cleanup ultimately passed: no project containers or transient
network remain, `.runtime/m19`, capture root and pointer are absent, and exactly the two
required M19 volumes remain preserved. The first cleanup attempt surfaced a PowerShell
inventory edge case for null empty container/network collections; a guarded check fixed
that, after which cleanup self-test and strict cleanup passed. The historical blocked
directory `C:\Users\marce\AppData\Local\Temp\geordi-m19-4541abc4d54c4f54b765b938fd06adf2`
was not touched and remains manual-removal/verification work.

The run exposed a burn-rate recovery failure that must be investigated and rerun. Review
also re-confirmed that the ordered M14 fixture recreates backend, frontend and Collector
services; Finalize now restores the M19 runtime services and records separate final logs.
The history fixture registers its newly generated webhook and browser flow credentials
in the private sentinel file. Finalize allows a silent OIDC fixture while including any
nonempty stdout/stderr from the fixture and every backend/frontend/Collector generation
it captures. These follow-up changes have not yet been exercised by a complete run.
Independent review of the final stabilized edits is pending. Removed intermediate
container generations still need capture before removal, and the full regression,
## Fresh local continuation checkpoint — 2026-09-25

The candidate remains based on `2601a4ee63924e843a50dc8940a8e193709e2f5b`; final status
contains 69 modified and 51 new paths (120 total). No reset, stash, discard, commit, push
or GitLab run occurred. The prior verified JAR and telemetry-extension digests remained
`082d7a4bf40fcdc605659186421adeee3456bf39dac3efd27ec4f6f4b97b2fdf` and
`44c7db976f8027437c853ad9ddb5b1a77aed50ac2104dd99a9f0106ec56582d2`; a no-cache local
runtime-image rebuild succeeded and checked the artifact provenance labels against those
values. The full current-candidate integration path did not start.

The fresh run stopped during ephemeral TLS setup, before Compose startup, Chromium,
credential activity, or any acceptance capture. Certificate-chain/SAN checks and Java
truststore generation completed. Installing that run's CA into Windows CurrentUser Root
then stalled. The original `Import-Certificate` operation did not return; a bounded
`certutil -user -f -addstore Root` attempt also exceeded 20 seconds, while a read-only
`certutil -user -store Root` query completed. The helper now bounds the trust-import
child process and reports failure without hanging; this run did not prove OS/browser
trust. No alternate certificate-validation bypass was used. Exact Windows trust-provider
cause remains undetermined.

Current-run cleanup passed after retrying Compose teardown with the same synthetic M13
fixture tokens configured by CI. It removed this attempt's `.runtime/m19` TLS directory;
no capture manifest or pointer had been created, and no Geordi container or transient
network remained. Exactly `geordi_m19-alert-lifecycle-data` and
`geordi_m19-victoriametrics-data` remain. The historical blocked path
`C:\Users\marce\AppData\Local\Temp\geordi-m19-4541abc4d54c4f54b765b938fd06adf2`
still exists and was not touched. Current mounted-truststore startup, backend HTTPS
discovery/JWKS, Chromium, serial M9–M18 regression, live nine-channel evidence,
mandatory Finalize, Loki/VictoriaMetrics acceptance queries, and current-run timing remain
unproven. The mandatory credential-gate simulations and cleanup/secret-scanner self-tests
passed, but are not substitutes for those live acceptance gates.

Current state remains `M19 NOT READY — REMEDIATION REQUIRED`.

## Isolated Windows certificate-store investigation — 2026-09-25

Per the current request, this investigation did not start Compose, Chromium, or any M9–M19
smokes. `investigate-first` and `lean-build` were applied: isolate the owning Windows
store behavior first and stop at the smallest failed acceptance gate. No production TLS
validation bypass or LocalMachine trust was used.

Evidence from one newly generated CA (chain/SAN validation and Java truststore generation
passed):

- The earlier `Import-Certificate` invocation did not return. Its root-store operation
  stage was not instrumented, so the exact blocking API is unknown.
- `certutil -user -f -addstore Root` as a hidden child exceeded its 20-second bound.
  A read-only `certutil -user -store Root` query completed.
- `X509Store.Add` completed when invoked directly in the active PowerShell session, but
  subsequent read-only enumeration found zero matching certificates. Before opening the
  logical store, the exact thumbprint also had no expected
  `HKCU\Software\Microsoft\SystemCertificates\Root\Certificates\<thumbprint>` entry,
  and the `ProtectedRoots\Certificates` value did not change.
- Direct `certutil -user -f -addstore Root` returned exit 0 and printed a generic
  successful-add message, yet independent exact-thumbprint enumeration again found no
  certificate. Therefore command success alone is not trust-installation proof.
- As a control, `X509Store.Add`, exact-thumbprint enumeration, and exact removal all
  passed in `CurrentUser\My`. The current-user root ACL grants the user full control;
  CryptSvc and CertPropSvc were running; the AuthRoot auto-update policy value was not
  configured; and the read-only certificate lifecycle log had no recent events.
- Microsoft documents that CurrentUser `Root` has special protected-root filtering and
  that opening this store removes unprotected SystemRegistry roots from its cache
  ([CertOpenStore](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certopenstore)).
  This matches the observed Root-specific non-persistence, but does not by itself explain
  the hidden-child timeouts.

Root-cause classification: **LIKELY — NOT CONFIRMED**: Windows CurrentUser Root protected-
root handling is preventing these API calls from establishing durable user trust; the
hidden-child timeouts may involve protected-root/provider interaction, but no prompt,
stdin wait, lock, or specific provider was directly observed. `CurrentUser\My` success
discards a general X509Store write failure. An explicit Group Policy denial and a generic
registry ACL denial are not supported by the available evidence; broader policy/provider
behavior remains open.

The isolated acceptance gate is **FAIL**. No successful Root import, exact-present proof,
native TLS handshake, or three independent generate/import/verify/remove cycles were
established. The full M19 run was not attempted. This is the required stop condition; do
not treat prior certutil success text as a pass. The single test CA was removed by its
exact recorded thumbprint; CurrentUser Root exact-match enumeration returned absent, the
generated runtime directory was removed, no capture pointer exists, and Docker inventory
confirmed zero Geordi containers and zero transient network. Both protected M19 volumes
remain. The historical blocked temp directory remains untouched. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

The test harness `scripts/Test-GeordiCertificateStore.ps1` records pre/post API stages for
exact Root Add/Remove investigations. Caveman skills used in this continuation:
`investigate-first` for evidence-ranked diagnosis and stop-before-edit; `lean-build` for a
narrow, standalone store probe without widening the runtime. No review skill was applied
because the isolated TLS gate did not pass and no closure review was appropriate.

Failure triage: the failing polling helper was waiting for the script's initial valid-zero
burn assertion; the last observed API result was SLO `BREACHED`, burn `AVAILABLE`, rate
`3.26923076923`. The smoke uses a fixed service identity and PT5M window while the
preserved M19 VictoriaMetrics volume survives prior runs. This makes prior fixture error
samples inside the current window a strong, evidence-based hypothesis for the initial
nonzero burn, but the failed-run series was removed by cleanup before it could be queried.
Treat the cause as likely stale fixture telemetry, not confirmed, until a bounded
precondition or isolated run proves it.

## Fresh isolated Windows trust-provider checkpoint — 2026-09-25

This continuation stayed on the current worktree and did not start Docker, Compose,
Chromium, M19 smokes, or the serial regression. It generated only temporary public CA
files under `%TEMP%`; no private key or secret was written or printed. No repository code
was changed because the first clean trust cycle did not pass.

The earlier `Import-Certificate` probe was incomplete because the clean child hosts did
not initialize the certificate provider consistently. With `Microsoft.PowerShell.Security`
loaded, PowerShell 7.6.6 still returned
`InvalidDestinationPath,Microsoft.CertificateServices.Commands.ImportCertificateCommand`.
Windows PowerShell 5.1 returned `DriveNotFound` for the same destination despite a fresh
host reporting the `Cert` drive, an existing `Cert:\CurrentUser\Root`, and an existing
public `.cer` input. This cmdlet path is not a viable unattended import on this host.

With redirected stdin closed, `certutil -user -f -addstore Root` did pass once: it exited
0 in 5.05 seconds and an independent new PowerShell process found exactly one certificate
with the expected thumbprint. On the first clean generated-and-validated CA/leaf cycle,
the same bounded import instead remained alive for 12.63 seconds. Before termination,
the process was `certutil`, CPU time was 0.03 seconds, its window title was
`Advertencia de seguridad`, it had one `UserRequest` wait thread and a `conhost.exe`
child. A fresh reader found zero exact matches. This directly confirms an interactive
Windows security-warning dialog can block the hidden, unattended import; closing stdin
does not dismiss that dialog. The exact dialog body was not read or automated.

Deletion evidence is also host-specific. X509Store removal exposed a window titled
`Almacén de certificados raíz`; the PowerShell certificate provider returned
`InvalidOperationException` stating that UI is not allowed for the user root store.
`certutil -user -f -delstore` likewise waited on that titled window. Microsoft documents
`-Silent` for `-delstore`; after the first probe's exact leaf had already been removed by
a narrowly targeted registry recovery, `certutil -Silent -delstore` exited 0 but could
not remove the now-orphaned thumbprint marker from `ProtectedRoots`. The user Root leaf
is absent from a fresh reader. The exact marker remains in the protected-roots binary
value: its pre-test size was 64 bytes and it now contains the 20-byte probe thumbprint as
a suffix (84 bytes total). Restoring the prior value was refused by the registry ACL; no
ACL or policy was changed. Do not treat this metadata residue as a successful cleanup.

The first clean end-to-end cycle failed at the trust-import step, so no further acceptance
cycles were run. No TLS bypass, LocalMachine trust, UI automation, policy/ACL edit, or
full M19 gate was used. The current fresh CA was never present in CurrentUser Root. The
earlier diagnostic CA has no Root certificate leaf, but its `ProtectedRoots` marker could
not be restored in this unattended session and requires operator cleanup through the
supported interactive Windows certificate-store flow. The diagnostic `%TEMP%` directory
`geordi-m19-store-diagnostic-current` also remains because local deletion was rejected by
the execution control; it contains public certificate/probe files only. It is separate
from and does not touch the historical blocked directory recorded above.

No `.runtime/m19` files or capture pointer were created, no Compose/Docker state was
started or altered, and the two required M19 volumes remain protected. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## Trust-model decision checkpoint — 2026-09-25

This checkpoint resolves the trust-store implementation question without changing
production code, TLS scripts, CI, machine/user trust, registry values, or protected
volumes. It is a documentation-only investigation on the current worktree. No Docker,
Compose, Chromium, M19 gate, or full regression was run.

### Frozen contract versus implementation choice

Slice 4 freezes an ephemeral CA with random, uncommitted key material; explicitly trusted
browser, Java, and PowerShell CI; ordinary certificate-chain and hostname validation; no
TLS bypass; and cleanup of generated private material and trust additions on failure.
It does not name a Windows certificate-store location. `CurrentUser\\Root` is an
implementation choice made by the present PowerShell helper and `.gitlab-ci.yml` job,
not a frozen acceptance requirement. Changing to a preprovisioned root would, however,
change the frozen per-run ephemeral-CA contract and needs an explicit design decision
before implementation.

### Supported trust paths considered

| Path | Ordinary validation | Per-run ephemeral trust | Privilege / scope | Finding |
| --- | --- | --- | --- | --- |
| `CurrentUser\\Root` | Yes | Intended, but import/removal has blocked on Windows security UI in this host | User scope; this execution observed a modal import and UI-requiring removal | Not proven unattended here |
| `LocalMachine\\Root` | Yes | Technically possible to add/remove a per-run root, but machine-wide | Windows machine store; supported command-line import requires local administrator/elevation | Not available to this medium-integrity non-admin process; no probe attempted |
| Group Policy root distribution | Yes | No; policy is administrator-managed and persistent/asynchronous | Domain/enterprise administration and broad policy scope | Not a per-run CI mechanism |
| CertMgr / CryptoAPI store APIs | Yes | Store mutation can be programmatic | Does not remove the underlying store permission boundary; CertMgr LocalMachine import requires elevation | No evidence that an API provides an unattended bypass for this host |
| Browser-specific root injection | Not established as a supported independent trust store | No supported per-run overlay found for Chromium on Windows | Chromium consumes OS and policy certificate stores | Not a demonstrated alternate path |
| Preprovisioned CI root | Yes, when provisioned in the runner OS trust store | No per-run root install; only leaves/private runtime material can remain ephemeral | Requires trusted administrator provisioning, protected signing key custody, isolation, rotation, and controlled runner assignment | Plausible design alternative, but these prerequisites and this job's runner mapping are unproven; it changes Slice 4's per-run ephemeral CA contract |

Official references: [Microsoft CertMgr](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/certmgr),
[Microsoft trusted-root troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-server/certificates-and-public-key-infrastructure-pki/valid-root-ca-certificates-untrusted),
[Windows machine and user certificate stores](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/local-machine-and-current-user-certificate-stores),
[Windows certificate stores](https://learn.microsoft.com/en-us/windows/win32/secauthn/certificate-stores),
[Group Policy certificate distribution](https://learn.microsoft.com/en-us/windows-server/identity/ad-cs/distribute-certificates-group-policy),
[Windows system-store locations](https://learn.microsoft.com/en-us/windows/win32/seccrypto/system-store-locations),
[certutil reference](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/certutil),
[CertAddCertificateContextToStore API](https://learn.microsoft.com/en-us/windows/win32/api/wincrypt/nf-wincrypt-certaddcertificatecontexttostore),
[Chromium Chrome Root Store FAQ](https://chromium.googlesource.com/chromium/src/%2B/a409df55512b6e330e488c1146f84ba0dba7dd76/net/data/ssl/chrome_root_store/faq.md),
[GitLab Windows Runner](https://docs.gitlab.com/runner/install/windows/), and
[GitLab Shell executor](https://docs.gitlab.com/runner/executors/shell/).

### Execution-context evidence and probe decision

The active PowerShell process runs as `MARCELO-DESKTOP\\marce` at medium integrity and
`WindowsPrincipal.IsInRole(Administrator)` is false. Thus the prerequisite for a
LocalMachine Root probe is not met. **LOCALMACHINE ROOT NOT UNATTENDED IN CURRENT
EXECUTION CONTEXT.** No elevation, UI automation, ACL/policy change, or alternative
privilege mechanism was attempted.

The project job `local_stack_smoke` requests tag `geordi-docker-pwsh`, has a
`geordi-local-stack` resource group, and invokes
`New-GeordiTestTls.ps1 -TrustForCurrentUser`. Locally, a `gitlab-runner` service is
running and its sanitized configuration indicates a `shell` executor using `pwsh`, but
the local configuration has no `geordi-docker-pwsh` tag literal. Since job tag assignment
may be managed by GitLab, this does not prove that this service receives the job or what
effective identity/integrity the job process has. A project resource group serializes
jobs in that group; it does not establish host-wide isolation from other processes.
GitLab documents that shell jobs execute on the runner host, which is not evidence of
the privilege of this specific job.

Preprovisioned CI trust is not accepted as the current solution: the runner-to-job
assignment, dedicated-host isolation, administrator ownership, signing-key custody,
thumbprint authorization, and rotation procedure have not been demonstrated. It also
replaces the frozen per-run ephemeral CA with a provisioned root and therefore requires
a deliberate contract/design update. Browser-specific trust and certificate APIs do not
provide a proven supported alternative that preserves the current contract on this host.

### Decision, confidence, and residuals

Selected outcome: **NO SUPPORTED UNATTENDED TRUST MODEL PROVEN**.

- **CONFIRMED:** the current interactive process lacks effective administrator rights;
  `CurrentUser\\Root` import previously displayed a security-warning window and the
  supported cleanup path displayed a root-store UI; the present job configuration names
  `CurrentUser\\Root`; the local Runner is shell/pwsh but is not locally matched to the
  project's job tag; no LocalMachine probe was run.
- **LIKELY:** LocalMachine Root could support ordinary TLS on an explicitly provisioned,
  elevated and isolated runner, but that would be machine-wide and cannot be approved
  from the available runner evidence. A preprovisioned CI root could be viable only after
  the contract and its custody/isolation controls are deliberately redesigned.
- **DISCARDED:** treating Docker availability or a running LocalSystem Runner service as
  proof that this project job has an appropriately isolated/elevated process; treating
  Group Policy or browser switches as per-run ephemeral trust; claiming the prior
  `ProtectedRoots` metadata residue is clean.

Trust cleanup remains split by residue. The prior CA leaf is absent from
`CurrentUser\\Root`, but its exact marker remains in the protected-roots binary value;
restoring that value was refused by its ACL. The diagnostic temp directory
`%TEMP%\\geordi-m19-store-diagnostic-current` contains public probe artifacts. Both
remain untouched and are **OPERATOR CLEANUP REQUIRED** through a supported interactive
Windows flow where applicable. The older blocked temp directory and both named M19
volumes also remain preserved. This checkpoint creates no additional TLS artifacts.

No clean trust-import/cleanup cycle passed in this continuation, so the required
three-cycle acceptance evidence does not exist. M19 full acceptance, container startup,
browser tests, telemetry capture, and regression gates remain NOT RUN. Do not proceed to
those gates until one supported unattended trust model is demonstrated and residue
handling is resolved.

This outcome is documentation-only; implementation is not ready. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## Windows GitLab Runner mapping checkpoint — 2026-09-25

This was a read-only investigation for the M19 `LocalMachine\\Root` trust-model
question. It preserves the prior checkpoint and all existing worktree content. No
pipeline, certificate probe, Docker/Compose, Chromium, M19 gate, or regression ran; no
service, GitLab setting, certificate store, registry value, ACL, policy, or volume was
changed. No diagnostic files were created.

### Job contract — repository facts

The versioned `.gitlab-ci.yml` defines `local_stack_smoke`, tag `geordi-docker-pwsh`,
resource group `geordi-local-stack`, 30-minute job timeout, `RUNNER_SCRIPT_TIMEOUT=27m`,
and `RUNNER_AFTER_SCRIPT_TIMEOUT=3m`. It sets `COMPOSE_FILE` to
`compose.yaml;compose.m19.yaml` and `GIT_STRATEGY=clone`. Its script expects Windows
PowerShell (`pwsh`), Docker Compose, Java/container tooling, npm, and Playwright Chromium;
it calls `New-GeordiTestTls.ps1 -TrustForCurrentUser`, then runtime/credential/security
checks and later M19 browser and semantic checks. Those are repository job requirements,
not evidence about any external runner registration or its effective security context.

### Local runner metadata and mapping confidence

Read-only service metadata showed one installed `gitlab-runner` Windows service:
`LocalSystem`, automatic start, running, with binary
`C:\\GitLab-Runner\\gitlab-runner.exe` and config
`C:\\GitLab-Runner\\config.toml`. The sanitized local config contains one runner block:
name `geordi-windows-runner`, URL host `gitlab.com`, executor `shell`, shell `pwsh`,
global `concurrent = 1`, and no `geordi-docker-pwsh` tag literal. No token or secret was
read into output. The local block does not show configured build/cache directories or a
per-runner `limit`. `check_interval = 0` is present. This establishes local configuration
only; tags and runner assignment can be maintained by GitLab.

**Mapping: POSSIBLE MATCH, not PROVEN MATCH.** There is no GitLab connector or existing
authenticated read-only project runner view available in this session, and no project
assignment evidence in the local config. The external relation
`local_stack_smoke -> geordi-docker-pwsh -> geordi-windows-runner` therefore remains
unknown. No evidence says it is a NOT MATCHED runner either.

### Effective security context and isolation

| Property | Result | Evidence / confidence |
| --- | --- | --- |
| Interactive account | `MARCELO-DESKTOP\\marce` | Confirmed in current PowerShell process; not the runner job identity |
| Interactive integrity | Medium | Confirmed in current PowerShell process; does not establish service/job token integrity |
| Interactive administrator membership | False | Confirmed with `WindowsPrincipal.IsInRole`; does not establish service/job membership |
| Runner service account | `LocalSystem` | Confirmed from Windows service metadata |
| Job effective account / SID / integrity | Unknown for this project job | No proven mapping and no job execution was permitted |
| Expected shell behavior | Local shell process using configured `pwsh` | GitLab documents Windows shell executor jobs run locally, and PowerShell Core is the configured/default shell; this is documented expectation for a matched runner, not job-specific proof |
| LocalSystem privilege implication | LocalSystem includes SYSTEM and Administrators SIDs with extensive local privileges | Microsoft documentation; documented token expectation for processes under that service account, not direct observation of this project's job token or certificate API outcome |
| UAC/elevation dependency | Unknown for job | LocalSystem service normally has a privileged service context, but exact job-token behavior and store operations were not exercised; interactive UAC cannot be automated |
| Runner count/config concurrency | One local service, one local runner block, global concurrency 1 | Confirmed on this machine; does not bound other services, manual host processes, or GitLab-side runners |
| Host exclusivity | **UNKNOWN** | No evidence establishes dedicated/project-limited use or absence of other local workloads |

The runner executor has limited isolation: GitLab warns shell jobs execute locally with
the runner user's permissions and can access other projects/workloads on that host.
`concurrent = 1` serializes jobs handled by this Runner process only. The job's
`resource_group` serializes jobs in that GitLab resource group only; neither proves
exclusive host use or prevents unrelated processes from observing/changing a temporary
machine-wide root.

### LocalMachine Root decision matrix

| Requirement | PASS / FAIL / UNKNOWN | Evidence |
| --- | --- | --- |
| Correct runner identified | UNKNOWN | Local candidate exists, but no authoritative project/tag mapping |
| Job shell identity known | UNKNOWN | Service is LocalSystem; this job was not mapped/executed |
| Effective administrative privilege established | UNKNOWN | LocalSystem documents a privileged token, but no concrete job token is proven |
| Unattended write possible in exact job context | UNKNOWN | No authorized same-context test; no cert import attempted |
| Exact unattended removal possible in exact job context | UNKNOWN | No authorized same-context test; no cert removal attempted |
| Runner/host isolation acceptable | UNKNOWN | No dedicated/shared assignment evidence; shell executor isolation is limited |
| Job serialization sufficient for host-wide trust mutation | FAIL | Resource group and Runner concurrency do not serialize outside jobs/processes on the host |
| Exact per-run thumbprint ownership | UNKNOWN | No machine trust probe/script run |
| Bounded cleanup | UNKNOWN | No machine trust probe/script run |
| Failure-path cleanup | UNKNOWN | No machine trust probe/script run |
| No other job depends on the CA | UNKNOWN | No runner/project workload inventory |
| CA private key remains ephemeral | PASS (contract only) | Slice 4 and current helper define generated random private material; no trust probe was run |
| No TLS bypass | PASS (contract only) | Slice 4 and CI design require normal verification; no M19 test was run here |

### Probe decision and residues

Probe not authorized because the first stop condition is unmet: the concrete runner that
can receive this tagged project job is not identified. Effective job token, machine-store
write/removal, and host isolation are also unknown. Running from the interactive medium
integrity shell would not satisfy the same-context requirement, while executing through
GitLab would violate the explicit no-pipeline boundary. No CA was generated or installed.

Pre-existing residues remain untouched: the prior `ProtectedRoots` marker, the public
diagnostic directory `%TEMP%\\geordi-m19-store-diagnostic-current`, the historical
blocked temp directory, and both named M19 volumes. Artifacts created by this task: none.
Cleanup from this task: not applicable.

### Decision

**RUNNER CONTEXT STILL UNPROVEN**

The available local evidence supports only a possible runner match. It cannot establish
the actual project assignment or safe isolation for machine-wide trust mutation. Do not
try `LocalMachine\\Root` until the exact matched runner context and isolation are proven.
If a supported per-run trust context cannot then be established, preprovisioned trust
would require an explicit change to Slice 4's per-execution ephemeral CA contract; that
alternative is not designed or implemented here. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## GitLab project runner evidence checkpoint — 2026-09-25

This is a read-only follow-up to the Windows runner mapping checkpoint. No GitLab setting,
runner configuration, service, certificate store, residue, volume, source code, or CI job
was changed. No pipeline/job was launched and no certificate probe was run.

### GitLab evidence

| Item | Result | Evidence |
| --- | --- | --- |
| Project job | `local_stack_smoke` | Versioned `.gitlab-ci.yml` |
| Required tag | `geordi-docker-pwsh` | Versioned job `tags` |
| Project runner inventory | Unavailable in this session | No GitLab connector/tool, `glab` CLI, GitLab environment variables, or authenticated read-only project view was available |
| Official read-only API route | `GET /projects/:id/runners` | [GitLab Runners API](https://docs.gitlab.com/api/runners/) documents project runner listing and prerequisites; no authenticated request was possible here |
| Local runner ID / server description association | Unknown | Local config name is not an authoritative GitLab ID or mapping |

The local machine still shows one `gitlab-runner` service (`LocalSystem`, automatic,
running) and one sanitized local config block: `geordi-windows-runner`, URL host
`gitlab.com`, executor `shell`, shell `pwsh`, `concurrent = 1`, no local tag literal.
These local facts do not establish the GitLab-side runner ID, type, online/paused state,
protected status, `run_untagged`, project association, or tags. No server metadata was
invented or inferred from the local name. GitLab runner inventory may require project or
group permissions and authenticated access, as described by its API documentation.

### Mapping and tag comparison

| Property | Job | Local runner / GitLab metadata | Match |
| --- | --- | --- | --- |
| `geordi-docker-pwsh` | Required | Local config has no tag; GitLab tags unavailable | UNKNOWN |
| Protected ref requirement | Not specified in this job stanza | Runner access level unavailable | UNKNOWN |
| Run untagged | Not material to this tagged job | Server property unavailable | UNKNOWN |
| Project scope | Project job | Runner type/project association unavailable | UNKNOWN |

Mapping classification: **STILL UNKNOWN**. The runner is only a possible local candidate;
there is no authoritative GitLab runner ID/description or association evidence. No
conclusion that it is matched or not matched is supported.

### Scheduling scope and host isolation

GitLab scheduling scope is **UNKNOWN** because project runner metadata could not be read.
If the local runner receives the job, its configured shell executor runs scripts on its
host and GitLab warns shell executor jobs have limited isolation; the actual match is
unproven. Local runner-process concurrency is 1, and the job's `geordi-local-stack`
resource group serializes only jobs assigned to that GitLab resource group. These facts
do not establish exclusive host use. Host classification remains **UNKNOWN** (neither
DEDICATED nor SHARED is proven); other services, manual processes, and workloads outside
the Runner process were not inventoried.

### LocalMachine eligibility and decision

Runner mapping was not resolved, so `LocalMachine\\Root` eligibility is not established
and remains deferred. No trust store was accessed or changed. To advance, obtain the
project's runner inventory through an already authorized read-only GitLab view/API and
compare its server-side ID and tag/scope metadata to the local Runner registration using
a safe, non-secret identifier; then separately establish host isolation and the job's
effective context. Any preprovisioned-root alternative still requires an explicit change
to Slice 4's ephemeral-per-execution CA contract.

Pre-existing residues (ProtectedRoots marker, diagnostic temp directory, historical
blocked temp directory, and the two M19 volumes) remain untouched. This checkpoint
created no artifacts and requires no cleanup. Worktree changes remain documentation-only
for this continuation; no commit, push, or pipeline was performed. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## Runner registration correlation checkpoint — 2026-09-25

This read-only checkpoint adds local runner evidence to the owner-provided GitLab
project inventory. It does not repeat Windows certificate-store investigation. No
GitLab pipeline/job, service change, certificate operation, Docker/Compose, M19 gate, or
M9–M18 regression was run. No trust store or pre-existing residue/volume was accessed.

### GitLab evidence supplied by the owner

The owner reports visual confirmation in GitLab project `geordi` settings that Project
Runner `#55099271` is online and carries tag `geordi-docker-pwsh`. This matches the
versioned `local_stack_smoke` required tag. Description/name, protected status,
untagged-job setting, runner-manager/system ID, and any host identifier were not supplied.
The server-side Project scope and online/tag facts are treated as owner-provided evidence,
not independently fetched in this session.

### Local registration evidence

The Windows service metadata identifies service `gitlab-runner`, account `LocalSystem`,
automatic start, and binary `C:\\GitLab-Runner\\gitlab-runner.exe`; the service config
contains local runner name `geordi-windows-runner`, URL host `gitlab.com`, executor
`shell`, shell `pwsh`, and global `concurrent = 1`. A bounded read of the GitLab Runner
event provider found prior polling attempts to `https://gitlab.com/api/v4/jobs/request`
logged with runner name `geordi-windows-runner`; those attempts failed on DNS/network
errors and do not show that this registration received or executed the M19 job. Runner
log records contain an opaque shortened runner reference, which is intentionally omitted
because it was not established as a non-secret public identifier and was not compared
with the server-side runner ID. The local `.runner_system_id` value is likewise not
correlated with any server-side manager metadata available here.

The initial bare `gitlab-runner list` invocation selected the repository's default
`config.toml`, not the service config, so it is not evidence about the installed service.
That invocation generated an untracked `.runner_system_id` in the worktree; its creation
time matched the invocation and it was removed immediately. A subsequent listing with
the explicit service config selected `C:\\GitLab-Runner\\config.toml` and did not yield
a server runner ID or project association. No runner verify request was made.

| Correlation signal | Server side | Local side | Result |
| --- | --- | --- | --- |
| Runner ID | `#55099271` (owner-provided) | No ID surfaced by local config/list/logs | No direct match |
| Scope / project | Project / `geordi` (owner-provided) | Local config has no project scope | No direct match |
| Tag | `geordi-docker-pwsh` (owner-provided) | No local tag literal | Cannot compare from local config |
| Description/name | Not supplied | `geordi-windows-runner` | Name match unavailable; do not infer |
| Manager/system ID | Not supplied | Local system ID exists | No comparison possible |
| Online activity | Online in GitLab UI (owner-provided) | Historical poll attempts reached log output but failed before job receipt | No job receipt proven |

Correlation classification: **LOCAL RUNNER CORRELATION STILL UNPROVEN**. The owner-provided
runner satisfies the job's server-side tag/scope facts, but no shared non-secret
identifier links it to the local service registration. There is no contradiction proving
NOT MATCHED either.

### Service context and host isolation

**CONFIRMED locally:** service identity `LocalSystem`; configured executor `shell`; shell
`pwsh`; global Runner concurrency 1; one GitLab Runner service and one registration block
were found. These are service/configuration facts, not observed job-process facts.

**DOCUMENTED EXPECTATION:** GitLab shell executor runs each job as a local process on the
runner host under the runner service's configured execution context; Microsoft documents
LocalSystem as a high-privilege local service identity. Because the exact server runner
and job execution were not correlated or run, the effective job account, token integrity,
and administrative privilege remain **UNKNOWN**, not confirmed.

A bounded search of Windows services found the GitLab Runner service and no services with
the common Jenkins, TeamCity, Bamboo, GitHub Actions, Azure Pipelines, Buildkite, or
CircleCI CI-agent names. This limited service inventory does not rule out non-service
agents, manually launched processes, external/project workloads, or other host uses.
There is no evidence declaring this machine exclusive to Geordi. Host isolation is
**UNKNOWN**, not DEDICATED and not SHARED.

`concurrent = 1` serializes only jobs managed by the local Runner process.
`resource_group: geordi-local-stack` serializes only GitLab jobs in that resource group.
Neither establishes host exclusivity or serializes unrelated host processes.

### LocalMachine readiness matrix

| Requirement | PASS / FAIL / UNKNOWN | Evidence |
| --- | --- | --- |
| GitLab runner `#55099271` identified | PASS (server inventory only) | Owner-provided GitLab project UI facts |
| Local registration matched | UNKNOWN | No shared server/local non-secret identifier |
| Windows service identity known | PASS (service only) | Service metadata says `LocalSystem` |
| `shell` / `pwsh` confirmed | PASS (service config only) | Explicit local runner config |
| Effective job privilege | UNKNOWN | No matched job execution; service identity is not direct job-token evidence |
| Host dedicated | UNKNOWN | Limited CI-service search cannot prove exclusive host use |
| No unrelated CI workloads | UNKNOWN | Only bounded Windows-service name search performed |
| Serialization sufficient | FAIL for host-wide exclusivity | Runner concurrency/resource group do not cover all host processes |
| LocalMachine mutation acceptable | UNKNOWN | No trust probe permitted or run |
| Failure cleanup feasibility | UNKNOWN | No trust probe or cleanup test run |

### Next-step decision

**LOCAL RUNNER CORRELATION STILL UNPROVEN**

No certificate probe is authorized by this evidence. A future read-only owner comparison
needs a shared non-secret runner or manager identifier from GitLab and the local
registration, plus positive host-isolation evidence, before LocalMachine readiness can
be reconsidered. Existing ProtectedRoots/temp-directory residues and both M19 volumes
remain untouched. The accidental `.runner_system_id` created by the incorrect default
listing was removed; no other artifacts were created by this task. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## LocalMachine probe preparation checkpoint — 2026-09-25

This continuation implemented a development/CI-only probe after confirming the current
interactive PowerShell context cannot perform machine-store mutations. It did not
investigate runner IDs again and did not execute a certificate-store operation. No
pipeline, Docker/Compose, Chromium, full M19, or M9–M18 regression ran. The existing
ProtectedRoots marker, diagnostic/historical temp directories, and both protected M19
volumes were not accessed.

### Execution context

The active PowerShell identity is `MARCELO-DESKTOP\\marce` (SID
`S-1-5-21-1411450029-2183844282-2373326557-1001`), medium integrity, and
`WindowsPrincipal.IsInRole(Administrator) = false`. The process therefore does not have
the required effective administrator context for `LocalMachine\\Root`; no elevation or
privilege workaround was attempted. **LOCALMACHINE PROBE REQUIRES RUNNER CONTEXT.**

### Reusable probe

Added `scripts/Test-GeordiLocalMachineTrust.ps1`. It is explicitly development/CI-only
and defaults to `-Mode ValidateOnly`, which creates two ephemeral authorities and a leaf
in memory, validates CA constraints, exact chain and expected SAN, and exercises exact
thumbprint selection without opening a certificate store. The runner invocation is
`pwsh -NoProfile -NonInteractive -File ./scripts/Test-GeordiLocalMachineTrust.ps1 -Mode Run`;
CI wiring was not changed in this checkpoint.

`-Mode Run` first requires effective Administrator membership and otherwise exits before
creating temp files or opening a store. When run in an authorized runner context it is
bounded to exactly three fresh CA cycles. It exports only each public CA certificate to
a unique temporary directory; CA and leaf private keys remain in memory and are disposed.
Store import, exact present verification, exact removal, and exact absence verification
are isolated in fresh noninteractive PowerShell child processes with 15-second limits.
Import validates that the file is public-only CA material and matches the expected
thumbprint and subject. Removal selects only the exact recorded thumbprint. A failed or
timed-out import triggers exact-presence inspection, exact removal if present, and
independent absence verification; uncertainty is reported as cleanup failure.

The TLS phase uses a loopback HTTPS fixture for `localhost` and the default
`HttpClient`/Windows certificate validation path: no validation callback, trust-all
handler, hostname bypass, or HTTP fallback. The DNS SAN and server-auth EKU are created
on the leaf. TLS/client and server operations are bounded to 10 seconds. The public CA
file and temporary directory are removed in `finally`; private keys and leaf material
are never written to disk.

### Validation and cycle results

| Cycle | CA unique | Import | Exact present | TLS | Remove | Exact absent | Cleanup | Duration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | N/A |
| 2 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | N/A |
| 3 | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | NOT RUN | N/A |

PowerShell parser validation passed. `ValidateOnly` passed for distinct authority
thumbprints, CA/leaf chain, SAN, and exact-thumbprint selection; it explicitly reports
that no certificate store was opened. No probe temp artifacts remained. This validates
generation/selection logic only; it does not prove machine-store import/removal or a TLS
handshake trusted by the Windows root store. Normal chain/hostname TLS acceptance is
therefore NOT RUN, not PASS.

The probe implementation was manually checked for bounded child/TLS operations,
public-certificate-only import, exact-thumbprint ownership, noninteractive behavior,
failure-path cleanup, and absence of TLS bypass callbacks. No independent reviewer agent
was used; no trust-model acceptance claim is made from this static review.

Current-task residue: the script and this checkpoint are the only new task artifacts;
ValidateOnly created no files. No store certificates or unrelated certificates were
changed. The current decision is **LOCALMACHINE PROBE REQUIRES RUNNER CONTEXT** and M19
remains `M19 NOT READY — REMEDIATION REQUIRED`.

## LocalMachine TLS integration checkpoint — 2026-09-25

The owner supplied the result of a corrected, clean elevated Windows PowerShell
probe run: `Test-GeordiLocalMachineTrust.ps1 -Mode Run` completed three fresh cycles,
with import, exact-presence verification, normal chain/hostname TLS, exact removal,
absence verification, and cleanup all PASS in each cycle. The owner also confirmed the
fixture uses a Schannel-compatible temporary leaf key and avoids re-declaring its
PowerShell type. This is owner-provided evidence, not a rerun in this session. The
probe's `ValidateOnly` mode was rerun here and passed without opening a certificate
store.

The production M19 TLS path now targets `LocalMachine\Root`: `New-GeordiTestTls.ps1`
requires `-TrustForLocalMachine`, records this run's exact public CA thumbprint, and
delegates bounded import and verification to a fresh noninteractive PowerShell child.
The child verifies thumbprint, subject, issuer, CA constraint, validity, and absence of
a private key; a separate exact-thumbprint query proves the imported certificate is
present once. `Remove-GeordiTestTls.ps1` validates the manifest against the public CA,
removes only that thumbprint, proves it absent, then removes run-owned TLS files. The
`.gitlab-ci.yml` caller was updated atomically. No `CurrentUser\Root` fallback remains
in this flow. Machine-store mutation requires an already elevated process; no automatic
elevation or privilege workaround is attempted. Bootstrap failure performs exact
thumbprint cleanup and retains the public manifest only when cleanup cannot be
confirmed, while removing private files.

PowerShell parser checks passed for all changed TLS/cleanup scripts and both trust
helpers; module import and `ValidateOnly` passed. The actual helper focal cycle was NOT
RUN: this session's process is medium-integrity and not an effective Administrator.
Its fail-fast `-TrustForLocalMachine` guard was exercised and failed before creating
`.runtime/m19`; the guard created no runtime material. Therefore the real helper's
LocalMachine import, M19-host HTTPS, `Finalize`, exact absence, and private-file cleanup
remain unproven in this session. No full M19 candidate, GitLab pipeline, Docker/Compose,
Chromium, M9–M18 regression, or full quality gate was run. Protected volumes and
historical temp/ProtectedRoots residues were not touched. No independent final review
was performed because the required fresh candidate and real-helper focal gate did not
run.

The next required step is the focused real-helper bootstrap/HTTPS/Finalize cycle in an
authorized elevated Windows dev/CI process. Only if that gate passes may a fresh full
M19 candidate and its independent final review begin. Current status remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## Focused LocalMachine gate and cleanup interpolation fix — 2026-09-25

The owner subsequently completed the real-helper bootstrap in elevated PowerShell:
`New-GeordiTestTls.ps1 -TrustForLocalMachine` created the Java truststore and imported
the ephemeral CA into `LocalMachine\Root`. This is owner-run evidence; the bootstrap was
not repeated here. During the focused gate, `Test-GeordiTestTls.ps1` passed normal
Windows TLS to `https://geordi.localhost:8443` with HTTP 200. The existing M19 fixture
connector was used with the default .NET certificate validator for
`https://auth.localhost:9445/health`, also HTTP 200. A direct host request initially
could not resolve `auth.localhost`; the fixture connector supplies the repository's
existing loopback routing while leaving normal chain and hostname validation enabled.

The owner reported that the first `Complete-GeordiM19Cleanup.ps1` attempt did not reach
Compose teardown: the helper's Compose file set includes `compose.m14.yaml`, whose
required `GEORDI_M13_WEBHOOK_TOKEN_A/B` interpolation values were absent. The owner
performed bounded recovery with the historical synthetic CI placeholders and ran the
existing Compose `down --timeout 10 --remove-orphans`; eight containers and the
`geordi_default` network were removed, while both protected M19 volumes remained.
The owner then reran the cleanup helper successfully with exact output:
`cleanup=passed containers=0 networks=0 tls=removed private_captures=removed preserved_volumes=2 original_failure_preserved=false`.
This is classified as a **cleanup harness/config interpolation defect**, not a TLS,
LocalMachine trust, Docker daemon, or permission failure. It closes the owner-run
focused bootstrap/HTTPS/Finalize gate; these results are owner-provided rather than a
fresh candidate run in this session.

The cleanup helper now supplies `m19-cleanup-interpolation-only-a/b` only in its
process environment when the required values are absent, runs the existing bounded
Compose teardown with `--remove-orphans` and no volume deletion option, and restores
the prior process environment immediately afterward. Existing non-empty values are
preserved. On Compose failure, the helper reports only a bounded allowlisted missing
variable name and exit code; other diagnostics remain suppressed. No `.env` file or
runtime/test credential behavior changed.

`Test-GeordiM19Cleanup.ps1 -SelfTest` now renders the exact Compose overlay with both
variables absent and with preexisting values, verifies restoration/no placeholder
residue, asserts there is no `down -v`, and checks that the cleanup inventory protects
`geordi_m19-alert-lifecycle-data` and `geordi_m19-victoriametrics-data`. The self-test
and PowerShell parser checks passed. No Compose services were started by the test.

The cleanup defect is remediated, but no fresh full M19 candidate has run. The next
candidate must generate a new ephemeral CA. The current Codex process is not elevated;
when the ordered candidate reaches `New-GeordiTestTls.ps1 -TrustForLocalMachine`, it
must stop for owner execution if effective administrator rights are still unavailable.
M19 remains `M19 NOT READY — REMEDIATION REQUIRED`.

## Cleanup fix and fresh-candidate backend gate — 2026-09-25

This session verified the post-owner cleanup preconditions read-only: `.runtime/m19`
was absent, no Geordi containers were listed, and both protected M19 volumes existed.
The owner-provided prior focused-gate results above were not rerun. No certificate was
generated or imported in this session.

The cleanup interpolation fix passed the PowerShell parser, its extended self-test,
and `git diff --check`. The self-test rendered the exact M19+M14 Compose configuration
with both M13 variables absent and with existing values; both renders passed and the
test process environment was restored after each case. It also checked volume-preserving
arguments and both protected-volume inventory names. Frontend `npm ci`, tests (235),
typecheck, lint, and production build passed; Vite reported the existing large-chunk
warning. The cleanup self-test did not start or stop Compose services.

The fresh backend verify gate failed before quality analysis/provenance: `mvnw clean
verify` ran 541 tests and recorded 16 errors (zero assertion failures), all affected
Spring integration contexts failing while discovering the local HTTPS OIDC fixture
metadata. The same 11 affected suites passed together when selected directly, and
`PlatformApiIntegrationTest` plus `AlertLifecyclePersistenceHealthIntegrationTest`
also passed individually. A full rerun under both installed JDK 26 and JDK 24 reproduced
the 541-test/16-error result. The available evidence narrows the symptom to full-suite
execution; it does not establish the underlying cause. No product/test changes were
made in response to this failure.

Per the candidate order, the failed backend gate stops this candidate before frontend
provenance staging, verified image build, fresh LocalMachine CA bootstrap, Compose
startup, semantic regressions, or credential evidence. The JDK 24 diagnostic log was
written to `D:\geordi-m19-backend-jdk24-build.log`; it contains build output only and
was not added to the repository. No GitLab pipeline was started. Current M19 status is
`M19 NOT READY — REMEDIATION REQUIRED`; resolve and rerun the full backend gate before
starting another candidate.

## Backend OIDC fixture order-contamination remediation — 2026-09-25

The Java 21 full-suite failure was isolated to JVM TLS state initialized by
`HttpWebhookNotificationSenderTest` before the first OIDC-backed Spring context. The
test constructed the production sender with its default `HttpClient`; Java's client
captured the JVM default `SSLContext` before `GeordiTestOidcFixture` installed its test
truststore properties. The later fixture certificate therefore was not trusted by the
already initialized default context. A temporary test-only diagnostic on the minimal
poisoner/victim pair observed `SunCertPathBuilderException`, confirming a trust-chain
failure rather than a missing fixture, stale port, connection failure, or timeout.
The order-dependent pair failed in a reused JVM and passed in a clean fork. The original
16 errors spanned 13 classes: the two alert lifecycle Spring tests, four bootstrap API
integration tests, `OidcIntegrationTest`, the logs API and module tests, the metrics API
and module tests, and the traces API and module tests. Focused runs passed because the
webhook poisoner was absent or ran in a fresh JVM before the OIDC-dependent victim.

The 16 Surefire error cases were:

- `AlertLifecyclePersistenceHealthIntegrationTest`: `reflectsPersistenceOutageAndRecoveryInPlatformHealthAndReadiness`; `missingDispositionTableMakesAlertsAndReadinessUnavailableUntilRestored`.
- `DisabledAlertLifecyclePersistenceHealthIntegrationTest`: `ignoresUnavailableLifecyclePersistenceWhenAlertsAreDisabled`.
- `DownPlatformApiIntegrationTest`: `keepsProductHealthAtHttp200WhileReadinessUsesOperationalStatus`.
- `ModuleInventoryIsolationIntegrationTest`: `inventoryDoesNotEvaluateHealthAndHealthEvaluatesOnce`.
- `PlatformApiIntegrationTest`: `exposesTheExactPlatformIdentity`; `exposesRegisteredModulesAndAggregatedHealth`; `exposesActuatorLivenessAndReadiness`.
- `UnknownPlatformApiIntegrationTest`: `keepsUnknownProductHealthAtHttp200ButMarksReadinessDown`.
- `OidcIntegrationTest`: `discoversIssuerValidatesTlsAndCompletesBoundPkceLoginIntoCanonicalSession`.
- `LogsApiIntegrationTest`, `MetricsApiIntegrationTest`, and `TracesApiIntegrationTest`: each `acceptsIsoUtcInstantsThroughTheRealSpringMvcConversionLayer`.
- `LogsModuleIntegrationTest`, `MetricsModuleIntegrationTest`, and `TracesModuleIntegrationTest`: each `disabledModuleRemainsInInventorySkipsHealthAndHasNoRoutes`.

`HttpWebhookNotificationSenderTest` now injects an explicit fail-closed SSL context
backed by an empty trust store into its plaintext-only webhook clients. This prevents
those HTTP tests from initializing/caching JVM-default TLS state and does not weaken
the production OIDC client's certificate validation. A regression test constructs the
webhook sender first, starts the real test OIDC fixture, and then makes a normal default
`HttpClient` HTTPS request to its health endpoint successfully.

Regression checks passed on Java 21 (Temurin 21.0.9 in the isolated Maven container):
the victim alone passed (2 tests), poisoner followed by victim passed (7 tests), and the
poisoner plus all 13 affected classes passed (21 tests). Two consecutive
`mvn -B -ntp clean verify` runs passed, each with 542 tests, zero failures, zero errors,
and zero skipped. Each run also completed PMD, SpotBugs with Find Security Bugs, and
ArchUnit successfully. The second run followed a fresh `clean`, confirming the fix is
stable across repeated full-suite executions.

This resolves the backend blocker. No fresh M19 candidate was started as part of this
backend-only remediation; current M19 remains `M19 NOT READY — REMEDIATION REQUIRED`
until its ordered fresh candidate is run.

## Fresh local M19 candidate — paused before LocalMachine TLS bootstrap — 2026-09-25

Candidate `599a9285f2ce4b9fac7d24097574dac8` started from base HEAD
`2601a4ee63924e843a50dc8940a8e193709e2f5b` with 70 modified and 53 untracked paths.
The initial diff check passed; both protected volumes existed; no Geordi containers,
project networks, `.runtime/m19`, or evidence recovery pointer existed. The existing
`backend/.ci-artifact` application and telemetry JARs were saved outside the worktree
before replacement with this candidate's build artifacts.

The authoritative Java 21 backend wrapper gate passed on Temurin 21.0.9: 542 tests,
zero failures/errors/skips, with PMD, SpotBugs/Find Security Bugs, and ArchUnit green.
The frontend job passed `npm ci`, 235 tests, typecheck, lint, and production build; Vite
reported the existing large-chunk warning. PowerShell parsing (38 scripts), Compose
overlay rendering, telemetry sanitizer, credential leak/gate and cleanup self-tests,
and Collector, Tempo, and Loki configuration checks passed. The OpenAPI document
declares 3.1.0; no standalone OpenAPI validator is defined in the current CI job or
repository scripts, so no separate schema-validation result is claimed.

Fresh backend, support, frontend, and OIDC fixture images were built. The Maven,
staging, and runtime application JAR SHA-256 values matched
`5a058bde3b454ef14f5f9852a978157f3c80b8681ccca13127ec1fcf17f4b1d6`; the telemetry
extension digest matched across build, staging, runtime, and image label. Backend image
ID is `sha256:313968e3cb7b1f65b3993d8e972579535797fa67eff6d54ab32f906805b3acdb` and its
revision label records the base HEAD above. Candidate evidence metadata and the saved
prior artifacts are in the local temporary candidate directory, outside the repository.

The monotonic elapsed time at the TLS gate was 1,146.9 seconds. The current PowerShell
process is not elevated, so execution stopped before calling
`New-GeordiTestTls.ps1 -TrustForLocalMachine`; no CA was generated and no trust store,
Compose service, or volume was changed. To resume this same candidate, the owner must
run that helper in an elevated shell from the repository root. Candidate status remains
`M19 NOT READY — REMEDIATION REQUIRED` pending owner output and the remaining ordered
gates.

## Fresh local M19 candidate — evidence bound exceeded — 2026-09-25

Candidate `599a9285f2ce4b9fac7d24097574dac8` resumed from the existing worktree and
runtime. The owner-run elevated LocalMachine bootstrap passed. HTTPS hostname and chain
validation, authenticated M19 security smoke, browser OIDC E2E, and the ordered M9–M18
regression scripts passed. Backend Java 21 verification (542 tests plus PMD,
SpotBugs/Find Security Bugs, and ArchUnit), frontend verification (235 tests, typecheck,
lint, and build), and the static/config checks recorded in the preceding checkpoint
also passed.

The first burn-rate run exposed a smoke guard that rejected the valid run-specific
namespace because it searched for the unchanged prefix rather than the exact original
YAML scalar. The guard now checks exact scalar values; the provider-failure/recovery
burn-rate smoke passed in 118.1 seconds. During evidence finalization, Windows .NET
could not resolve `geordi.localhost`; the capture helper now uses the same loopback-only
connection strategy as the existing native TLS helper while retaining normal SNI,
hostname, and certificate validation. A subsequent process-identity check also exposed
PowerShell JSON date coercion; timestamp comparisons now use UTC ticks in finalization
and cleanup. The RFC 9457 capture request and process identity checks passed after
these corrections.

Evidence finalization then stopped at the existing 64 MiB capture bound: the live
OpenTelemetry Collector log had grown to 70,272,561 bytes, and the companion final
capture added another 12,929,332 bytes. The bound was not raised and the private logs
were not truncated or replaced. The manifest is incomplete, so the required final
credential artifact scan did not run and no credential-evidence PASS is claimed.
The candidate therefore remains `M19 NOT READY — REMEDIATION REQUIRED`; no fresh
candidate has been started.

The owner subsequently supplied the elevated helper output
`cleanup=passed containers=0 networks=0 tls=removed private_captures=removed
preserved_volumes=2`. Post-cleanup checks confirmed `.runtime/m19` and the evidence
pointer are absent, Geordi containers and networks are both zero, and both protected
volumes remain present. The pre-candidate ignored `application.jar` and
`security-telemetry.jar` were restored from the external backup and their SHA-256
digests match the saved copies. No commit, push, or GitLab pipeline was performed.
M19 remains `M19 NOT READY — REMEDIATION REQUIRED` because the credential evidence
manifest could not pass its size bound and the required final artifact scan did not run.

## Credential evidence acquisition remediation — 2026-09-25

The previous candidate's stop is classified as a **credential-evidence acquisition
bound / harness scalability defect**. The 64 MiB check applied both to each physical
Collector file and the aggregate logical channel. The leak scanner then loaded each
file into a byte array, and the positive-control collector joined decoded file contents
in memory. The manifest already represented a channel as an array of paths, but did
not record ordered byte identities, hashes, or coverage. The live follower log and
the final `docker compose logs` capture are both retained because they span the
current-run live interval and the finalization snapshot; their exact byte overlap could
not be measured after the owner's successful cleanup removed the private captures.
Both complete sources are retained and scanned independently, so overlap does not
discard or conceal source bytes.

`scripts/lib/GeordiPrivateEvidence.ps1` now scans Collector and OTel captures in 64 KiB
blocks, hashes each complete file incrementally, carries an overlap tail across block
boundaries, and fails if the file is missing, empty, changes, or exceeds the bounded
logical-channel budget. The limit is 512 MiB per logical channel, reusing the scanner's
existing total expansion ceiling rather than bypassing the old limit with segments or
truncation. The scanner's working set does not grow with capture size. Manifest version
2 records the run and capture interval, ordered file identity and path, full byte range,
per-file byte count and SHA-256, logical byte count, the applicable limit, overlap
policy, and positive-control result. No raw capture is copied into the manifest or
published artifacts.

The runtime and persisted credential gate and the publishable-artifact scan now run as
independent phases after finalization is attempted. Thus an incomplete Collector
capture or credential-gate failure no longer prevents the independent publishable
artifact scan from running. `.gitlab-ci.yml` also runs the synthetic over-64-MiB
regression during deployment-configuration validation.

Focused remediation validation passed: PowerShell parser; normal credential scanner
self-test; synthetic 64 MiB + 4 KiB complete capture; positive controls before and after
64 MiB; raw, URL-encoded, JSON-escaped, base64, and base64url sentinels after 64 MiB;
exact 64 KiB boundary-crossing sentinel; reordered metadata, missing-source, and empty
channel rejection; private test-material cleanup; required-gate valid and fail-closed
cases including artifact-scan independence; cleanup-policy self-test; independent
publishable-artifact scan (235 files, 4 archives, 1,549 entries); PowerShell parser for
all changed scripts; and `git diff --check`.

The former candidate remains unpromotable: its Finalize did not produce a complete
manifest and its final artifact scan did not run. This remediation does not claim a
credential-evidence PASS for that candidate and does not change the milestone status:
`M19 NOT READY — REMEDIATION REQUIRED`. A fresh candidate is required to exercise the
new collector path and the authoritative full gate order; its build, TLS bootstrap,
runtime captures, manifest, and artifact scan must all be new candidate evidence.

The fresh candidate has identity `2e2c3551e3254992838120ff1b41a1d0`. The owner's latest
`backend/salida.txt` records Java 21.0.12.1, 542 tests with zero failures/errors/skips,
and `BUILD SUCCESS` after PMD, SpotBugs/Find Security Bugs, and ArchUnit. The frontend
gates passed (235 tests, typecheck, lint, production build). Compose overlays and
telemetry sanitizer configuration passed. Fresh backend image labels matched the
candidate revision and both artifact hashes; support, frontend, and OIDC fixture images
also built successfully.

The candidate is paused at the LocalMachine TLS bootstrap because the current process
is not elevated. Preflight found zero Geordi containers/networks, no `.runtime/m19` or
evidence pointer, and both protected volumes present. No certificate was generated and
no Compose service was started. The previous ignored `application.jar` and
`security-telemetry.jar` were restored and their saved SHA-256 hashes verified; the
fresh candidate artifacts, hashes, and phase state are held under the system temporary
candidate directory. Resume this candidate by running
`pwsh -NoLogo -NoProfile -File .\scripts\New-GeordiTestTls.ps1 -TrustForLocalMachine`
from the repository root in an elevated PowerShell. Do not reuse candidate
`599a9285f2ce4b9fac7d24097574dac8` evidence. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED` until the fresh runtime and final evidence gates
pass.

## Fresh M19 candidate — Collector basic verbosity exercised; gates incomplete — 2026-09-25

The current candidate run ID is `0b9113465de64110a2efa4c6ff2e4936`. The owner-run
LocalMachine bootstrap was present and the exact CA matched once. Collector config,
Compose overlays, artifact revision/JAR/image hashes, Java 21 backend evidence, and
the focused PowerShell scanner/parser checks passed. The updated Collector is mounted
with `verbosity: basic`; `verify-otel.ps1` now checks non-empty trace and metric summary
records, while the ordered persistence gates remain responsible for resource identity.
That focused gate passed in this run. This is runtime evidence for the new output shape,
not a M19 acceptance claim.

The ordered chain passed through M13: OTel, metrics, traces, logs, service map, SLOs,
burn-rate/provider-failure, alert evaluation, M10 lifecycle, M11 notifications, M12
scheduling/overlap, and M13 routing. The M14–M18 history gate failed after 467.58 s
against its 480 s budget. The first wrapped capture-start invocation also stalled and
was interrupted; the same candidate was continued from its started manifest, then
native TLS, runtime preflight, security smoke, and Chromium E2E passed. Browser evidence
contains seven private sentinel classes before later history activity.

Final evidence acquisition did not complete. `Invoke-GeordiM19CredentialGates.ps1`
reported `finalize=FAIL credential_scan=FAIL artifact_scan=PASS`; the independent
publishable artifact scan executed and passed for 236 files, 4 archives, and 1,550
entries. The manifest has no completion timestamp or completed channel metadata, so no
nine-channel, Loki, VictoriaMetrics, or runtime credential-scan PASS is claimed. A
bounded read-only check reproduced the Loki query-range timeout at 15 s. The full
timing ledger is incomplete, including the owner-run bootstrap and the interrupted
capture-start wrapper.

The owner subsequently ran `Complete-GeordiM19Cleanup.ps1` elevated and reported
`cleanup=passed`, `containers=0`, `networks=0`, `tls=removed`,
`private_captures=removed`, and `preserved_volumes=2`. Local post-cleanup checks confirm
`.runtime/m19` and the private evidence pointer are absent, zero matching containers
and networks remain, and both protected volumes are present. The exact CA thumbprint
was not independently queried after cleanup because its runtime record was removed;
the cleanup script's TLS removal result is recorded as owner-reported evidence. No
second fresh candidate has been started. The independent review found one HIGH and two
MEDIUM findings in the Collector-basic evidence/assertion changes, and the current
candidate still lacks complete runtime evidence. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## Credential-evidence remediation — focused gates pending — 2026-09-25

The prior review findings are being remediated without starting another full M19
candidate. `verify-otel.ps1` restores the persisted backend identity assertions;
`Test-GeordiCredentialGate.ps1` now reaches the credential matcher for synthetic
backend and unrelated VictoriaMetrics-label leaks by keeping capture metadata and
the byte ledger consistent. The Collector remains at `verbosity: basic`.

VictoriaMetrics evidence now uses bounded raw `/api/v1/export` samples, not a
15-second `query_range` resample. Each generation snapshot is scoped from the active
capture start through its snapshot time and is retained in the private evidence
manifest before its dedicated M10–M14/M19 metric generation changes or is removed.
Repeated captures of a phase replace that phase's snapshot with a complete run-start
export. The aggregate limit is 64 MiB and overflow fails closed. The final persisted
source gate validates JSONL samples, resource identity, timestamps, byte accounting,
and the security-metric positive control. Regression coverage includes a zero-valued
unrelated series and a short-lived series.

Capture startup now has regression coverage for a hung launcher and descendant
cleanup; process identity and diagnostic files remain available if cleanup cannot be
confirmed. The M14–M18 timing ledger records failed persistence operations and failed
cleanup as well as successful durations. A focused Loki persisted-source check uses a
bounded request, readiness gate, current-run range, positive control, and sentinel
scan.

Offline remediation checks passed: PowerShell parser; required credential-gate and
large-capture scanner self-tests; Loki and VictoriaMetrics persisted-source
self-tests; capture-start timeout/cleanup self-test; OTel identity self-test;
cleanup and Collector sanitizer self-tests; Collector configuration validation; and
`git diff --check` (line-ending warnings only). The independent re-review is pending.
No focused runtime Loki or M14–M18 history gate has run since these edits, and no new
M19 candidate has started. The earlier owner-reported cleanup still preserves both
protected M19 volumes; exact LocalMachine CA absence for that candidate remains
unverified. Status remains `M19 NOT READY — REMEDIATION REQUIRED`.

## Credential-evidence remediation — independent review clear, runtime gates pending — 2026-09-29

The independent remediation review found and the implementation corrected three
issues: VictoriaMetrics export now selects the dotted OTLP resource labels emitted by
the configured Collector while validation retains underscore-label compatibility;
the normal M11-to-M12 teardown now records a zero-byte handoff only when the complete
M11 final snapshot ledger is present and Docker confirms the prior VictoriaMetrics
container is removed; and each Loki request/retry is bounded by the remaining gate
deadline, rejecting late responses. The removed-generation handoff has focused
regression coverage for missing and empty temporary files.

The independent reviewer re-reviewed these changes with zero BLOCKER, HIGH, MEDIUM,
or LOW findings. PowerShell parsing, the VictoriaMetrics raw-export/handoff
self-test, Loki persisted-evidence self-test, required credential-gate self-test, and
`git diff --check` pass. No live M14–M18 history or Loki gate has run since
remediation, the current worktree has no `.runtime/m19` bootstrap, no fresh full M19
candidate has started, and the prior candidate's exact LocalMachine CA absence
remains unverified. Status remains `M19 NOT READY — REMEDIATION REQUIRED`.

## Focused runtime gates — PASS; elevated cleanup pending — 2026-09-29

The owner supplied a fresh elevated LocalMachine bootstrap. Read-only verification
confirmed the exact recorded CA occurs once in `LocalMachine\Root`; the private TLS
runtime and capture pointer were initially in the expected state. M19 Compose
configuration, Windows-native HTTPS trust/hostname validation, runtime preflight,
and the live Loki persisted-source gate passed. Loki returned 9 current-run entries
within its 35-second bound and all five sentinel scan forms passed.

The M14–M18 history gate exited 0. Its timing ledger recorded fixture startup and
readiness at 42.23 seconds, total wait time at 99.23 seconds across 381 polls,
compose time at 45.05 seconds, persistence checks at 19.24 seconds, and 8 M18
checks. VictoriaMetrics run-bound generation snapshots passed at M14 reset/final
phases, and the removed M11-to-M12 generation handoff has offline regression
coverage. The two protected M19 volumes remain present.

Strict cleanup has not run. The current process is not elevated; there are 10
Geordi containers and one `geordi_default` network from the focused runtime, and
the exact run CA is still present once in `LocalMachine\Root`. Do not start the
fresh full M19 candidate until the owner runs the existing cleanup elevated and
reports success; then perform a new owner-run LocalMachine bootstrap for that
candidate. No full M19 candidate has started. Status remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## Focused runtime cleanup — PASS; fresh candidate bootstrap pending — 2026-09-29

The owner ran `Complete-GeordiM19Cleanup.ps1` elevated and reported
`cleanup=passed`, `containers=0`, `networks=0`, `tls=removed`,
`exact_thumbprint_absent=true`, `private_captures=removed`, and
`preserved_volumes=2`. Local post-cleanup checks confirm `.runtime/m19`, the capture
pointer, and public thumbprint record are absent; there are zero Geordi containers
and zero `geordi_default` networks; and both protected M19 volumes remain present.
The exact thumbprint itself is no longer available for an independent store query
because cleanup removed its metadata; the cleanup script's exact-absence result is
the recorded proof.

The focal HTTPS, preflight, Loki, and M14–M18 gates passed as recorded above. No
fresh full M19 candidate has started. Since cleanup removed the ephemeral TLS
runtime, the next required action is an owner-run elevated
`New-GeordiTestTls.ps1 -TrustForLocalMachine` bootstrap. The full candidate must then
run once from a fresh capture and still satisfy every M19 acceptance gate before
closure. Status remains `M19 NOT READY — REMEDIATION REQUIRED`.

## Fresh M19 candidate — first OTel gate failed; cleanup complete — 2026-09-29

Fresh candidate run `41cbf01c508a4c65b75f16583f703802` started after the focused gates
and cleanup passed. Collector configuration validation, verified backend image
provenance, supporting image builds, stack readiness, capture startup, Windows-native
TLS, runtime preflight, browser E2E, and security smoke passed. The first ordered
gate, `verify-otel.ps1 -TimeoutSeconds 120`, failed with the sanitized diagnostic:
`Persisted backend JVM Resource identity did not match the platform API version.`
The ordered chain stopped immediately; no later M9–M18 gates or final evidence gates
were run, and the candidate is not accepted.

The owner then ran the existing elevated cleanup and reported
`cleanup=passed`, `containers=0`, `networks=0`, `tls=removed`,
`exact_thumbprint_absent=true`, `private_captures=removed`, and `preserved_volumes=2`.
Local checks confirm `.runtime/m19` and the capture pointer are absent, there are no
Geordi containers or transient network, and both protected M19 volumes remain.

Read-only inspection of a temporary copy of the protected VictoriaMetrics volume
found 100 backend JVM series with two distinct complete resource-identity tuples;
both carried version `0.1.0-SNAPSHOT` and the expected service, namespace, origin,
component, environment, and non-empty instance attributes. The diagnostic copy and
its temporary resources were removed. This does not explain why the gate rejected
the live response, so no root cause is claimed. The gate’s 60-second series-listing
window can include samples from prior runtime generations, and the series endpoint
does not expose sample timestamps. `verify-otel.ps1` now anchors the identity series
lookup to after its controlled requests and additionally requires a successful
bounded 90-second `count_over_time` query for a JVM series with the current platform
version and required resource attributes. Its self-test and PowerShell parser pass;
`git diff --check` passes with existing line-ending warnings. This revised check has
not yet run against a live candidate and is not proven to resolve the failure.

M19 remains `M19 NOT READY — REMEDIATION REQUIRED`. Because strict cleanup removed the
ephemeral runtime TLS material and exact CA metadata, the owner must perform a fresh
elevated `New-GeordiTestTls.ps1 -TrustForLocalMachine` bootstrap before a future
candidate. No new candidate, pipeline, commit, or push was started.

## OTel query defect remediation — focused proof passed; elevated cleanup required — 2026-09-29

Candidate `59ded49c7c264519aeca0ae343516a1c` was frozen before Compose with HEAD
`2601a4ee63924e843a50dc8940a8e193709e2f5b`, 70 modified paths, 57 untracked paths,
clean `git diff --check`, the owner-provided LocalMachine CA, both protected volumes,
and no stale Geordi containers/network. Its first OTel gate failed because both the
series selector and the identity query encoded `{__name__=~"jvm\..*"}`; the final
MetricsQL parser rejected that escaped representation with HTTP 422. Replacing the
matcher with `{__name__=~"jvm[.].*"}` preserves the literal `jvm.` prefix without
backslash escaping. The focused self-test proves selector text, literal-prefix
semantics, URI round-trip without double escaping, required identity/version
predicates, and rejection of missing instance/version mismatches.

Against the still-running candidate runtime, VictoriaMetrics accepted both the
current-window series request and the identity-filtered `count_over_time` request;
current JVM samples with the current backend identity/version were present. The OTel
gate then passed: spans and metric points were accepted/exported, refusal/failure
counters did not increase, persisted JVM identity/version matched, and Collector
basic trace and metric summaries were present. PowerShell parser, OTel self-test, and
`git diff --check` passed. This proves the focused query remediation only; the frozen
candidate cannot be promoted because its script changed after candidate creation, and
no full regression was run.

The required strict cleanup was attempted, but this process is not elevated. Compose
containers and network were removed; runtime TLS, exact CA trust, and the private
capture pointer remain. Both protected M19 volumes remain present. The owner must run
`pwsh -NoLogo -NoProfile -File .\scripts\Complete-GeordiM19Cleanup.ps1` in elevated
PowerShell. After cleanup is verified, a completely new candidate needs new TLS
material, build/provenance, focused and full ordered gates. Status remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## OTel selector fix — focused pass; cleanup verified; next candidate awaits TLS — 2026-09-29

The owner completed elevated strict cleanup with `cleanup=passed`,
`containers=0`, `networks=0`, `tls=removed`,
`exact_thumbprint_absent=true`, `private_captures=removed`, and
`preserved_volumes=2`. Local verification confirms `.runtime/m19` and the capture
pointer are absent, no Geordi project containers or `geordi_default` network remain,
and both protected M19 volumes are present. Cleanup removed the public thumbprint
metadata, so the new candidate must bind newly generated TLS evidence.

The focused OTel query remediation on candidate
`59ded49c7c264519aeca0ae343516a1c` is proven: replacing the escaped-dot matcher with
`jvm[.].*` was accepted by the active VictoriaMetrics parser for both series listing
and current-run identity sample queries. The live OTel gate passed request/export
flow, persisted backend identity and version, and Collector basic trace/metric
positive summaries. Parser, seven-case focused self-test, and `git diff --check`
passed. Candidate `59ded49c7c264519aeca0ae343516a1c` remains ineligible for closure
because the gate changed after it was frozen; no full regression ran on it.

A new candidate must be frozen from the corrected worktree, use a newly owner-bootstrapped
LocalMachine CA, rebuild and verify artifact provenance, then run the focused OTel gate
before the authoritative full ordered sequence. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## Fresh candidate c1fa4c5b13ee49449da9d5ce8359fb43 — notification gate stopped — 2026-09-29

The corrected-worktree candidate passed its fresh backend `clean verify` (542 tests,
zero failures/errors, PMD and SpotBugs/Find Security Bugs clean), new verified runtime
image provenance, no-cache supporting image builds, owner-run LocalMachine TLS setup,
Compose startup, Windows-native TLS, runtime preflight, focused OTel, security smoke,
browser E2E, metrics, traces, logs, service map, SLOs, burn-rate/provider failure,
alert evaluation, and lifecycle gates.

The ordered chain stopped at `verify-notification-delivery.ps1` after 128.09 seconds.
Its `finally` ran M11 fixture cleanup. The sanitized gate exception was
`Private M19 container generation snapshot exceeded its bound.` Inspection of the
retained generation files showed the failing backend/VictoriaMetrics log snapshot was
20,253 bytes (stderr 0 bytes) and its file write interval was about 21 seconds, so
the 64 MiB size bound was not the cause. `Capture-GeordiM19Generation.ps1` waited only
20 seconds for `docker compose logs`; this exceeded that time limit. Later M11 output
was 80,968 bytes and completed in about 17 seconds. The gate diagnostic was scanned
against private sentinels and had no matches. Scheduling, overlap, routing, history,
final evidence gates, and final review did not run; this candidate is not accepted.

The bounded Compose log wait is increased to 30 seconds based on the measured 21-second
execution, with timeout and size-bound failures now reported distinctly. PowerShell
parsing, the OTel query self-test (7 cases), Collector sanitizer configuration,
`docker compose ... config --quiet`, and `git diff --check` pass. A new backend
`clean verify` completed with 542 tests, zero failures/errors/skips, PMD clean, and
SpotBugs/Find Security Bugs clean. A no-cache `ci-runtime` image was built from the
verified JAR and security telemetry extension; its source revision and artifact digest
labels match the build inputs. The changed helper has not run against a fresh candidate.

The owner completed strict elevated cleanup with
`cleanup=passed containers=0 networks=0 tls=removed exact_thumbprint_absent=true
private_captures=removed preserved_volumes=2 original_failure_preserved=false`.
Local checks confirm no Geordi containers or networks remain and both protected
volumes remain. Before a new candidate may start, the owner must perform a fresh
elevated LocalMachine TLS bootstrap so that its exact public CA thumbprint can be bound
to the new candidate. No Compose runtime or M19 gate has started since cleanup. M19
remains `M19 NOT READY — REMEDIATION REQUIRED`.

## Finalize attempt-isolation remediation — diagnostic stop — 2026-09-29

The Finalize harness now uses unique attempt-scoped outputs and process records,
atomic manifest publication, immutable failed-attempt files, a completed-manifest
guard, keyed persisted-source metadata, and fail-closed recovery/cleanup for unresolved
process launches. Parser, attempt self-test, credential-scanner self-test, cleanup
self-test, and `git diff --check` pass. The independent review reported zero BLOCKER,
HIGH, and MEDIUM findings.

The still-running candidate `f0fb022ba2ab4b7a81f366b4e0e0c4d4` was used once for
diagnostic proof only and is not eligible for M19 closure because the harness changed.
Attempt `20413fa7499d4caaa1eb8e3aaf39693d` completed Tempo search (5 intervals,
10,643 traces) and stopped during Tempo detail acquisition with sanitized
`failure_class=transport`. No Loki, VictoriaMetrics, credential scan, artifact scan,
or completion phase ran after that failure. No cleanup was run; the active runtime,
capture root, TLS material, and both protected volumes remain available for diagnosis.
The transport cause is not established. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## Tempo detail transport comparison — 2026-09-29

The exact trace set from attempt `20413fa7499d4caaa1eb8e3aaf39693d` was not
persisted, so it could not be replayed. A fresh current-run Tempo search produced one
in-memory set of 16,516 eligible traces; trace IDs and detail bodies were not emitted
or persisted. On this identical set, both serial diagnostic modes returned HTTP 200
for 9,822 details, then stopped before ordinal 9,823 because the configured 64 MiB
aggregate evidence bound would be exceeded. The fresh-client mode took 90.052 seconds;
the shared-client mode took 81.780 seconds. Both retained 60+ seconds of their
150-second deadline. Neither mode encountered a transport exception, per-request
timeout, or overall deadline.

Periodic TCP samples showed fresh-client `TIME_WAIT` rising with request count (9,832
at its stop; zero `ESTABLISHED`, `CLOSE_WAIT`, and `SYN_SENT`). Shared-client samples
showed one `ESTABLISHED` connection and declining `TIME_WAIT` (3,837 at its stop;
zero `CLOSE_WAIT` and `SYN_SENT`). This supports connection churn in the fresh-client
path but does not prove it caused the earlier transport failure: both modes stopped at
the same aggregate-size gate before completing the full set. Classification for the
original failure remains **G — still not proven**. No retry/Finalize, unrelated gate,
cleanup, or source lifetime fix was run. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## Frozen-set Tempo client comparison — 2026-09-29

The earlier 17,700-trace list was unavailable, so one new ordered, deduplicated set
was searched and frozen privately for a controlled diagnostic comparison. Its safe
identity is SHA-256 `971747b5ecaf50109028a7d5b734b7a3c172aa8ad4a2a6bea716b6b069e1a6f7`;
the set contained 18,537 traces across 9 search intervals. The private list was removed
after both modes ran and was not printed or added to the manifest.

Fresh-client-per-detail mode stopped after 10,550 details and 72,077,151 bytes at
104.995 seconds, with 45 seconds remaining. The sanitized transport evidence was
HTTP 200 followed by `HttpRequestException` / `SocketException` with
`AddressAlreadyInUse`. The bounded TCP sampler recorded no matching states. Shared-
client mode ran serially against the identical frozen set, consumed 105,718,160 bytes
across 16,668 details, then reached the unchanged 150-second overall deadline. It did
not encounter a transport failure; its TCP samples showed at most one ESTABLISHED
connection and zero TIME_WAIT, CLOSE_WAIT, and SYN_SENT.

This is a measured 150-second Tempo acquisition scalability blocker. Because shared
mode did not complete the same set, the comparison does not meet the specified proof
for classifying per-request client lifecycle as the cause of the fresh-mode socket
failure. The full logical byte count is still unknown. No harness fix, bound change,
Finalize, unrelated gate, cleanup, or TLS bootstrap ran. The runtime and both protected
volumes remain active. Candidate `f0fb022ba2ab4b7a81f366b4e0e0c4d4` stays diagnostic-
only; M19 remains `M19 NOT READY — REMEDIATION REQUIRED`.

## New frozen-set Tempo client comparison — 2026-09-29

The prior 18,537-ID list was unavailable and was not reconstructed. A new private,
ordered list was created from one bounded search and kept unchanged until both modes
and this comparison completed. The file is
`.runtime/m19/tempo-experiment-bd95fa4290b9461abc51df7ec6596cb2/ordered-trace-ids.private`,
with owner-protected ACL, 19,752 IDs, 651,815 bytes, created
`2026-09-29T21:22:34.0462869+00:00`, and SHA-256
`2c526a826e506ee35b06ce261468ef11b1a89e165a72b8107ecd46de3e048583`. Its count and
hash were verified before each acquisition and again after both; the file remains
private in the active runtime pending later cleanup.

Shared-client mode completed all 19,752 serial detail requests: 126,708,587 bytes,
largest response 11,958 bytes, 154.406 seconds, 6,414.975 average bytes/detail and
127.923 details/second. No request failed; sampled TCP counts showed at most one
ESTABLISHED connection and zero TIME_WAIT, CLOSE_WAIT, and SYN_SENT.

Fresh-client-per-detail mode used the identical verified list and failed after 14,781
details and 97,734,397 bytes at 132.973 seconds, with HTTP 200 on the last available
response and `AddressAlreadyInUse` from the socket transport. The bounded TCP sampler
recorded zero matching states. Since shared-client completed this exact set while
fresh-client failed with socket exhaustion under otherwise equivalent serial request,
8-second per-detail, per-response 64 MiB, and zero-retry semantics, the evidence now
supports **A — per-request HttpClient lifecycle / connection churn**. The earlier
150-second deadline is also insufficient: shared acquisition alone took 154.406
seconds. No production bound or timeout was changed.

Measured sizing proposal, for review only: a 32 MiB segment target yields four
segments for the observed 126,708,587 bytes. A finite 160 MiB logical maximum provides
41,063,573 bytes (32.4%) above this measured set and corresponds to five nominal target
segments. Keep each response record whole; stream framed records into ordered segment
files, rolling before a record that would cross the target and allowing a single record
up to the existing 64 MiB per-response bound. Add a 256-segment hard cap. At an
estimated ceiling of 512 bytes per manifest segment entry, metadata would use at most
128 KiB; adding that to the current 84,019-byte manifest remains well under the 1 MiB
manifest bound. Stream scanning across file blocks and segment joins keeps working
memory bounded; compute per-segment SHA-256 and exact record/byte coverage, and reject
missing, duplicate, reordered, incomplete, or changed segments.

The detail-only measurement means a Tempo phase budget must exceed 154.406 seconds.
The production Finalize deadline is global and starts before runtime restore, captures,
and Tempo search, so this experiment does not justify a precise new global timeout;
those preceding durations must be included from a fresh timing ledger. The measured
detail phase uses 9.53% of the 27-minute script budget and 8.58% of the 30-minute job
budget, leaving 24:25.594 and 27:25.594 respectively for every other phase. Combining
the previously recorded 1,086.49-second M9–M18 chain would leave 6:19.104 of the
27-minute budget, but that historical chain is not current-candidate timing evidence.

No segmented-channel implementation, timeout change, Finalize, unrelated gate,
cleanup, commit, push, pipeline, or M20 work was performed. Candidate
`f0fb022ba2ab4b7a81f366b4e0e0c4d4` remains diagnostic-only. M19 remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## Fresh diagnostic candidate after Windows restart — 2026-09-30

Candidate `6fe4e83ffaf7418ebcc7015a4c176b61` was created at HEAD
`2601a4ee63924e843a50dc8940a8e193709e2f5b` from the existing dirty worktree. The
owner supplied successful elevated LocalMachine TLS bootstrap evidence. The exact
public CA identity was verified against LocalMachine trust and the runtime truststore;
private TLS material is not recorded here. Local build provenance corresponds to this
candidate's dirty HEAD (backend JAR SHA-256
`70a127405084372b9eec810edd62db04086fc2a4cbd53feb3a09939ea4e3a978`; security
telemetry extension SHA-256
`a00473a382a5dd3f0d8b23b4335c2e39f0d99e0db47b9bde7b71f3c12a54517a`).

Focused harness parser and Tempo, Loki persisted-evidence, credential-scanner,
Finalize-attempt, and cleanup self-tests passed, as did `git diff --check`. Backend
`clean verify` passed with 542 tests; frontend tests (235), typecheck, lint, and build
passed. Runtime TLS, authenticated preflight, security, browser OIDC/CSRF, OTel,
metrics, traces, logs, service map, SLO, burn-rate, and M9–M13 gates passed.

The authoritative chain stopped at M14. The failed timing phase was
`M14_initial_condition_and_episode` (35.96 s), with the sanitized gate result
`M14 route A did not create ALERT_STARTED`. M14 fixture startup/readiness measured
44.65 s and fixture cleanup/restore 6.27 s. M14 aggregate timing recorded compose
37.82 s, waits 40.40 s, traffic 0.06 s, and browser 0.12 s. This evidence identifies
the gate symptom but does not establish a deeper root cause. M15–M18 and diagnostic
Finalize did not run. Therefore Tempo, Loki, VictoriaMetrics, runtime credential scan,
artifact scan, diagnostic publication, and complete Finalize timing remain NOT RUN;
no production timeout proposal is justified.

The candidate has no Finalize attempt or accepted/completed marker. Because the
attempt-time `DiagnosticOnly` manifest marker is written by Finalize, it was not
written after the earlier M14 stop. This candidate is barred from promotion by this
execution record, and the manifest marker requirement remains unmet. At stop, 11
Geordi containers and one project network were present; both protected M19 volumes
remained present. Cleanup was not run, no prior attempt files were modified, and
automatic retries were zero. Diagnose the M14 route-A lifecycle failure before
authorizing a new run. Status remains
`M19 NOT READY — REMEDIATION REQUIRED`.

## M11 backend generation integration — offline validation — 2026-10-04

The authoritative M11 script now routes its three backend replacement boundaries
through the shared generation handoff lifecycle: initial joint backend/VM reset,
backend downtime for pending-delivery recovery, and backend replacement for the
application-restart assertion. The M11 reset still captures and binds its persisted
metric snapshot to VM_OLD, then verifies a distinct VM_NEW. VictoriaMetrics remains
persisted snapshot evidence, not a log-follower generation. Standalone M11 cleanup
seals the active backend generation before removing its fixture.

Offline validation passed: M11 synthetic generation/volume tests; M11 Compose
propagation-isolation config render; M11 final-evidence and VM-identity tests; all
seven focused M10 replacement cases; M12 Collector replacement self-test; parser
validation for 10 affected PowerShell scripts; and `git diff --check`. The focused
independent read-only review reported BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0. The
volume-removal adapter now requires a successful inventory to establish absence,
rejects inventory/inspection errors, enforces exact M11 Compose ownership, and
cannot target either protected M19 volume.

This proves synthetic/config-only harness behavior. No M11/M12/M14 runtime, Docker
lifecycle, Finalize, cleanup, TLS, capture, or protected-volume operation was run.
M11→M12 fixture transfer is not implemented in this slice. Candidate
`6fe4e83ffaf7418ebcc7015a4c176b61` remains diagnostic-only; Gate 5 remains blocked,
Gates 6–17 remain NOT RUN, and overall status remains
`M19 NOT READY — REMEDIATION REQUIRED`. Next action: owner review before starting the
separate M11→M12 transfer slice or any later gate.

## M11→M12 fixture transfer capability — focused offline proof — 2026-10-04

Implemented an explicit default-false `-PreserveFixtureForNextStage` producer mode
for M11 and `-ConsumeTransferredM11Fixture` consumer mode for M12. M11 preserves
the fixture only after successful assertions, immutable `m11-final` evidence, active
backend generation/follower identity, live backend/VM/Collector ownership, and exact
M11 volume labels validate. The standalone M11 failure/success cleanup path remains
the default. M12 independently reloads the persisted manifest, revalidates those
identities and owned volumes, captures `m12-reset` against the inherited VM with log
snapshot skipped, verifies the source and current-run interval, then exits before
the future destructive M12 backend boundary. No transfer schema/artifact or CI
activation was added.

Offline focused validation passed: parser for four affected scripts; transfer
self-test including success-only preservation, producer failure cases, fresh-process
consumer proof, reset-interval binding, mixed-mode rejection and consumer rejection
matrix A–S; M11 final-evidence regression; shared capture-generation manifest
regression; and `git diff --check` (line-ending conversion warnings only). The fresh
independent read-only review reported BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0 / INFO 0.
Shared generation/evidence helpers are unchanged.

This is capability validation only. No Docker runtime, live M11/M12, TLS, captures,
cleanup, or protected-volume operation ran. M11 backend generation remains
OWNER ACCEPTED; M11→M12 transfer capability is OWNER ACCEPTED and is not CI-activated;
M12 backend generation remains NOT IMPLEMENTED. Gate 5 remains BLOCKED, Gates 6–17
remain NOT RUN, candidate `6fe4e83ffaf7418ebcc7015a4c176b61` remains DIAGNOSTIC ONLY,
and M19 remains `M19 NOT READY — REMEDIATION REQUIRED`. Next action: owner review
before the separate M12 backend generation boundary slice.

## Atomic M11→M12 CI activation — offline test remediation — 2026-10-04

The existing M11→M12 CI activation is implemented in the authoritative
`local_stack_smoke` sequence. Test-only remediation hardened the activation
contract to parse actual PowerShell command AST parameters and require each
activation switch exactly once in bare form. Attached `:$false`, `:$true`,
expression, duplicate, mixed, comment-only, unrelated-command, and unrelated-job
forms are rejected. M12 consumer-only validation now accepts only a literal
integral zero exit code; the signed fractional fixture is verified against the
PowerShell parser's `ConstantExpressionAst` / `System.Double` representation.
Metric snapshot and ledger fingerprints are recorded at publication/reuse and
checked after subsequent generation boundaries and at the end of the ordered
synthetic chain.

The complete remediation micro-suite passed. Formal gates 1–19 passed from Gate 1,
including the fresh-process M11→M12 proof, seven backend generations, six completed
backend handoffs, metric phase immutability and protected-volume checks. The fresh
independent read-only review reported BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0 / INFO 0.
`git diff --check` passed with line-ending conversion warnings. No production script,
CI wiring, shared helper, Docker runtime, TLS, capture, or protected volume was
changed during this test remediation. This remains offline/synthetic evidence;
runtime proof was not run. Atomic M11→M12 CI activation is READY FOR OWNER ACCEPTANCE;
M12 backend generations remain OWNER ACCEPTED. Gate 5 remains BLOCKED, the candidate
remains DIAGNOSTIC ONLY, and M19 remains `M19 NOT READY — REMEDIATION REQUIRED`.
Next action: owner review before any runtime gate.


## 2026-11-17 — Publishable-artifact gate refactor planning checkpoint

This addendum records a separate, documentation-only planning slice on
`fix/m19-log-follower-json-dates` at baseline
`50cff4143ab315509abfcb55707a96b8dd71411d`. It does not alter the M19 acceptance
status or supersede earlier runtime evidence.

### Contract analysis and approved plan

The owner-approved plan is
[EXECPLAN-M19-PUBLISHABLE-ARTIFACT-GATE.md](EXECPLAN-M19-PUBLISHABLE-ARTIFACT-GATE.md).

- PLAN-T01 — analysis of `Test-GeordiCredentialGate.ps1`,
  `Test-GeordiCredentialGateRequired.ps1`, and
  `Test-GeordiPublishableArtifacts.ps1`: **COMPLETE**.
- PLAN-T02 — shared publishable-artifact module interface specification:
  **APPROVED**, owner decision option A on 2026-11-17.
- Implementation at the initial planning checkpoint: **NOT YET AUTHORIZED**; this was superseded by the owner's explicit authorization later on 2026-11-17.

The approved design extracts publishable-artifact enumeration, inventory/hash
validation, archive inspection and path-safety checks into
`scripts/lib/GeordiPublishableArtifacts.psm1`. Production and SelfTest will use the
same validation rules with different explicitly supplied roots. Reparse points are
rejected, existing inspection limits are retained, and public script parameters/output
contracts are preserved.

### Findings that motivate the refactor

The current Credential Gate SelfTest still enumerates real repository build outputs.
The observed local invocation stopped at the precondition:

`Gate self-test requires built publishable artifacts.`

This is a SelfTest/build-output coupling finding, not proof that the production artifact
gate itself is defective.

A separate fixture-contract gap was identified: the synthetic manifest does not provide
the accepted Finalize attempt (`acceptedAttemptId` and `attempts`) required by the
Required Gate, and its Tempo fixture lacks the segment metadata required by the existing
credential scanner. Therefore the positive synthetic manifest case cannot satisfy the
current production validation contract. The approved correction is to complete the
synthetic fixtures, not to relax production validation.

### Compatibility prerequisite and safety boundary

The exact local PowerShell edition/version output is still outstanding. Before
implementation, record:

```powershell
$PSVersionTable.PSVersion.ToString()
$PSVersionTable.PSEdition
```

Then confirm the compatibility target against supported repository/CI environments.
The planning phase is closed, but this prerequisite blocks implementation until resolved.

No module or script was created or modified in this planning slice. No backend/frontend
build, M19 Begin/Finalize, Docker/Compose lifecycle, cleanup, TLS operation, private
capture inspection, `.runtime/m19` access or protected-volume operation was authorized
or performed as part of this plan.

**Overall M19 status remains `M19 NOT READY — REMEDIATION REQUIRED`.** The approved
offline design plan is not M19 acceptance evidence and does not promote any runtime,
credential, artifact or Finalize gate to PASS.


## 2026-11-17 — Publishable-artifact gate implementation checkpoint

The owner explicitly authorized implementation after approval of PLAN-T02. Source changes have now been published to `fix/m19-log-follower-json-dates`.

### Source changes

- Added `scripts/lib/GeordiPublishableArtifacts.psm1` with exported inventory, inventory-validation and archive-content validation functions.
- Refactored `scripts/Test-GeordiPublishableArtifacts.ps1` to delegate manifest-backed and independent inspection to the module. Existing `-ManifestPath` and `-Independent` behavior/output are retained; optional `-RootPath` selects the explicit synthetic root for SelfTest.
- Updated `scripts/Test-GeordiCredentialGate.ps1` to build synthetic backend reports/JARs, frontend output, inventory and a segmented Tempo fixture under its own temporary capture root.
- Added the accepted Finalize attempt fixture, with one completed attempt, the six required PASS phases, and channel/additional-source state bound to the published manifest.
- Added negative cases for missing accepted attempt, failed Finalize phase, malformed Tempo metadata, missing required artifact, inventory mismatch/duplicate/traversal, digest mutation, forbidden archive paths, malformed ZIP and reparse-point rejection where the host permits symbolic-link creation.
- Kept `Test-GeordiCredentialGateRequired.ps1` as the private-evidence gate. It does not call the artifact module; the artifact scan remains an independently orchestrated gate, preventing credential-gate status from being coupled to artifact-gate status.

### Verification status

The source has been written through the connected GitHub repository integration. No PowerShell parser, Credential Gate SelfTest, focused artifact scan, build or CI job has been executed in this session. The implementation is therefore **source-level only; verification is PENDING**. The prior failure message about built artifacts is historical and is the condition this SelfTest refactor is intended to remove; no new PASS result is claimed.

The repository documents PowerShell 7 as the Windows integration runner and the existing scripts use PowerShell 7 JSON support. PowerShell 7 is the implementation target. The exact local `$PSVersionTable` output remains outstanding before local execution can be claimed compatible.

No M19 Begin/Finalize, `New-GeordiCredentialEvidence.ps1` action mode, Docker lifecycle, cleanup, TLS/certificate operation, `.runtime/m19` inspection, private capture inspection or protected-volume operation was performed as part of this implementation. The existing safe-diagnostics step in SelfTest may query Docker container status; it does not perform a lifecycle action.

**M19 remains `M19 NOT READY — REMEDIATION REQUIRED`.** This implementation and its synthetic tests are not runtime credential-leak evidence, artifact acceptance evidence or milestone closure.


## 2026-11-17 — Publishable test-report diagnostic filtering

Local read-only enumeration of the existing artifact roots found two `.dumpstream` files beneath `backend/target/surefire-reports`. The recursive artifact inventory would have included these test-runner diagnostics alongside XML/TXT test reports.

The owner authorized a scoped policy correction. The publishable-artifact module now excludes `.dump` and `.dumpstream` files (case-insensitive) only beneath Surefire and Failsafe report roots. XML/TXT reports remain included; no exclusion applies to other roots. The synthetic SelfTest adds positive report-inclusion assertions, negative diagnostic-exclusion assertions, and a scope-boundary assertion for a `.dumpstream` file under `frontend/dist`.

This is a source-level implementation checkpoint only. Parser, SelfTest, independent artifact scan, CI and independent review remain pending for this correction. No local artifact, M19 runtime, `.runtime/m19`, private capture, TLS material, Docker resource or protected volume was modified or inspected. Overall status remains **M19 NOT READY — REMEDIATION REQUIRED**.


## 2026-11-17 — SelfTest StrictMode defect correction

The first local run of the updated Credential Gate SelfTest failed with the sanitized `artifact_validation_failed` result. Inspection found that the artifact inventory loop accessed the optional `excludeDiagnosticFiles` Hashtable key for every artifact definition. Under `Set-StrictMode -Version Latest`, definitions without that key caused an exception. The module now checks `ContainsKey` and defaults the exclusion switch to false for all other roots. This preserves the intended Surefire/Failsafe-only scope.

The correction is published as source only. Parser and SelfTest re-execution remain pending. No M19 runtime or protected resource was touched. M19 remains **NOT READY — REMEDIATION REQUIRED**.
