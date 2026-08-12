# TDD evidence — Milestone 1 backend

## RED

The behavior and architecture tests were written before production classes.

Command executed from `backend/` on 2026-08-12:

```text
mvn test
```

Result: `BUILD FAILURE` during `testCompile`, exit code 1. Representative missing
production contracts were `ModuleRegistry`, `PlatformModule`, `ModuleStatus`,
`ModuleSnapshot`, `PlatformHealth`, `ModuleConfiguration` and `GeordiApplication`.

## GREEN

After the minimum implementation, the same command completed successfully with 17
tests passing. A subsequent contract-hardening test was then added for product-health
HTTP 200 versus Actuator readiness HTTP 503 when platform state is DOWN, bringing the
suite to 18 tests.

Initial milestone verification:

- `.\mvnw.cmd -B -ntp verify`: `BUILD SUCCESS`, 18 tests, PMD check passed,
  SpotBugs/Find Security Bugs reported zero bug instances and zero errors;
- `docker build -t geordi-backend:milestone-001 .`: `BUILD SUCCESS`; the same gates
  ran cleanly on Eclipse Temurin 21.0.11 inside the build stage.

## Post-review regression

Two tests were added before the post-review production correction:

- enabled module `UNKNOWN` remains `UNKNOWN` with HTTP 200 in the product API, while
  Actuator readiness reports `DOWN` with HTTP 503;
- a thrown module health check notifies a framework-neutral failure observer while its
  exception remains absent from the product-health representation.

The RED command `.\mvnw.cmd -B -ntp test` failed during `testCompile` because the new
`ModuleHealthFailure` contract did not yet exist. After implementation, 20 tests pass.

Final post-review verification ran `verify` both on the host and in the Java 21 Docker
build stage: 20 tests passed, PMD passed, and SpotBugs/Find Security Bugs reported zero
bug instances and zero errors.
