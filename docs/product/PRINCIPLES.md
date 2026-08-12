# Product and Architecture Principles

## 1. Modular by Design

Capabilities must be independently activatable where practical. The product must not force all customers to deploy every feature.

## 2. OpenTelemetry Everywhere

Use OpenTelemetry and OTLP as canonical telemetry standards. Avoid proprietary telemetry protocols and agents unless compatibility requires an adapter.

## 3. The Observer Must Be Observable

Geordi must expose health, metrics, traces where relevant, and structured logs for its own components. Platform telemetry must be distinguishable from customer telemetry.

In Milestone 1 these requirements apply only to the runtime verification described by
the milestone acceptance criteria; they do not imply telemetry storage or exploration.

## 4. Replaceability by Design

Geordi should support entering an existing environment gradually, coexisting with other platforms, validating parity, and allowing exit without proprietary lock-in.

## Engineering corollaries

- modular monolith before microservices;
- standards before proprietary formats;
- ports/adapters at true external boundaries;
- domain independence from vendors and frameworks;
- test architectural rules automatically where possible;
- implement roadmap features only when their milestone begins.
