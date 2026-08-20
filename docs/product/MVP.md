# MVP Definition

Status: PLANNED

This is the product MVP target, not the scope of Milestone 1. Milestone 1 establishes
only the platform foundation required for it. Roadmap milestones v0.2 through v0.4
introduce the P0 telemetry capabilities incrementally.

Milestone 2 delivered a constrained operational Metrics view. Milestone 3 completed the
second P0 increment: persistent trace search/detail plus Metrics → Traces context
navigation. Milestone 4 is complete. Milestone 5 locally verifies Logs and Trace → Logs
correlation, pending the authoritative GitLab revalidation; therefore the correlated
telemetry MVP is not complete yet.

## Goal

A user must be able to move from "a service is unhealthy" to evidence that helps explain why, using correlated telemetry.

## Target MVP capabilities

P0:
- OpenTelemetry ingestion;
- service discovery;
- RED metrics;
- distributed tracing;
- trace detail;
- logs explorer;
- trace/log correlation.

P1:
- dashboard;
- service map (READY FOR GITLAB REVALIDATION: bounded trace-derived observed dependencies, not complete architecture);
- basic infrastructure monitoring;
- threshold alerts;
- email/webhook notifications.

## Explicit non-goals for early MVP

- full Kubernetes monitoring;
- RUM;
- session replay;
- synthetics;
- profiling;
- SIEM;
- cloud cost management;
- advanced incident management;
- AI RCA;
- hundreds of integrations.
