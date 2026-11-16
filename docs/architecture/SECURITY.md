# Security implementation status

M19 authentication and authorization are implemented in this worktree, but the
milestone is not locally closed or ready for deployment. The authoritative design,
evidence and remaining gates are in [`MILESTONE-019.md`](../plans/MILESTONE-019.md).
Do not treat the test OIDC issuer, ephemeral CA, or local TLS ingress as production
identity or certificate configuration.

The bootstrap security module validates signed API access tokens and exact
issuer/subject identity, maps configured external grants to immutable explicit
permissions, and protects the API through the HTTPS frontend ingress. Permissions are
`observability:read`, `alerts:acknowledge` and `alerts:evaluate`, with no implicit
inheritance. Browser login uses OIDC authorization code with PKCE, host-only in-memory
sessions and CSRF-protected mutations. The React client loads `/api/me` and gates
capabilities without storing OAuth credentials in browser storage. These paths have
backend, frontend and real-browser test coverage; final CI and complete milestone gates
remain required.

V8 adds authenticated acknowledgement attribution without rewriting legacy actor,
reason or timestamp values. Existing INSERT column sets default to
`LEGACY_CALLER_ASSERTED`; the authenticated writer requires an explicit principal.
ACK requests accept a reason only, and the server derives immutable attribution from
the authenticated OPERATOR. ACK and RESOLVE retain the episode-row serialization
boundary. Public routes enforce the permission matrix, and the API exposes attributed
history through the protected history endpoints.

Configuration uses `geordi.security.issuer`, `api-audience`, `browser-client-id`,
`browser-client-secret-file`, `public-base-url`, `grant-claim`, and `grant-mapping`.
The secret file contains exact printable client-secret bytes, without a trailing
newline. Secret-bearing configuration is not retained in configuration records or
written to diagnostics. API audience differs from browser client ID; external grants
map only to their explicit permission sets. The local test stack creates ephemeral
CA-signed certificates and mounts a Java truststore; deployment still needs validated
external issuer, audience, grant mapping, TLS, secret inputs and the documented
maintenance rollout.

The telemetry foundation packages a thin `security-telemetry` agent extension alongside
the application JAR. The pinned Java agent supplies its SDK; the extension wraps span
exporters to remove backend request URLs, captured headers/bodies and exception text
before export. Monitored application resources retain their existing telemetry.
This uses the documented [Java agent extension SPI](https://opentelemetry.io/docs/zero-code/java/agent/extensions/).
The implementation has browser and Compose security smoke coverage, but the full
positive-controlled nine-channel runtime leakage proof and sanitized failure-path
capture remain pending. Collector
`attributes/security` is defense in depth before debug/storage exporters; its
configuration was validated against the pinned core 0.157.0 distribution.

Security observations accept only closed enums, never request strings or identities.
nginx access output contains fixed categories and status; raw parser diagnostics are
suppressed. CI diagnostics require a private capture manifest and never print raw
Compose logs. The private scanner requires nonempty captures and positive controls
for browser, nginx, backend, problems, OTel, Collector, Tempo, CI and artifacts. Its
self-test verifies synthetic leak rejection; live channel evidence is not available yet.

Do not use an intermediate slice for a mixed-version rollout. A pre-M19 binary removes
authentication regardless of V8's additive schema compatibility. The final maintenance
rollout, isolated rollback procedure, CI integration and ADR-022 remain required before
closure.
