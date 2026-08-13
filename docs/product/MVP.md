# MVP Definition

Status: PLANNED

This is the product MVP target, not the scope of Milestone 1. Milestone 1 establishes
only the platform foundation required for it. Roadmap milestones v0.2 through v0.4
introduce the P0 telemetry capabilities incrementally.

Milestone 2 is the first P0 increment: a constrained operational Metrics view for one
selected Java service. It does not complete the correlated-telemetry MVP; trace and log
work remains in later milestones.

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
- service map;
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
