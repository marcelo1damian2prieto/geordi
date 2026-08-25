# MVP Definition

Status: PLANNED

This is the product MVP target, not the scope of Milestone 1. Milestone 1 establishes
only the platform foundation required for it. Roadmap milestones v0.2 through v0.4
introduce the P0 telemetry capabilities incrementally.

Milestone 2 delivered a constrained operational Metrics view. Milestone 3 completed the
second P0 increment: persistent trace search/detail plus Metrics → Traces context
navigation. Milestone 4 is complete. Milestone 5 completed Logs and Trace → Logs
correlation, completing the correlated-telemetry P0 baseline. Milestone 6 completed the
bounded, trace-derived observed dependency view. Milestone 7 completed a bounded,
deployment-managed SLO evaluation foundation after complete local verification,
independent review, and the project owner's confirmation that the authoritative GitLab
pipeline is green. Milestone 8 is complete and adds current-window
error-budget burn evidence to the same SLO snapshots; it does not add budget accounting.
Milestone 9 is in progress to add stateless alert-condition evaluation, not alert
delivery. The broader MVP target remains planned because delivery and other P1
capabilities are still deferred.

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
- service map (COMPLETE: bounded trace-derived observed dependencies, not complete architecture);
- SLO evaluation foundation (COMPLETE; no runtime CRUD or alerts);
- current-window SLO error-budget burn evidence (COMPLETE; no
  compliance-period accounting or alerts);
- alert-condition evaluation (M9 READY FOR GITLAB REVALIDATION; read-only policies and no notification
  delivery or lifecycle);
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
