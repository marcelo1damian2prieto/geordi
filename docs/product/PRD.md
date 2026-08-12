# Geordi Product Requirements Document

Status: FOUNDATION IMPLEMENTED / FUTURE CAPABILITIES PLANNED

## Vision

Geordi is a modular, OpenTelemetry-native observability platform that helps organizations understand distributed systems while preserving interoperability and minimizing vendor lock-in.

## Problem

Organizations commonly face one or more of these problems:
- fragmented metrics, logs and traces;
- expensive or inflexible SaaS observability platforms;
- operational complexity in open-source stacks;
- vendor-specific instrumentation and query models;
- disruptive migrations between observability products;
- poor visibility into the observability platform itself.

## Product proposition

Geordi combines:
- a unified observability experience;
- modular deployment;
- open telemetry standards;
- compatibility with existing systems;
- self-observability;
- gradual migration paths.

## Core principles

1. Modular by Design.
2. OpenTelemetry Everywhere.
3. The Observer Must Be Observable.
4. Replaceability by Design.

## Deployment modes

### Overlay
Geordi provides a unified experience over existing observability infrastructure.

### Hybrid
Some signals/providers are owned by Geordi and others remain external.

### Full Replacement
Geordi owns the complete telemetry path and user experience.

## Planned capabilities

- core platform;
- metrics;
- logs;
- traces;
- APM;
- infrastructure monitoring;
- service map;
- alerts;
- compatibility/migration;
- self-observability;
- future AI-assisted incident analysis.

## Milestone 1 scope

Status: IMPLEMENTED

Milestone 1 provides:
- platform core;
- module abstraction/registry;
- enable/disable configuration;
- platform/module health;
- backend API;
- minimal frontend overview;
- OpenTelemetry self-instrumentation;
- local OpenTelemetry Collector.

Milestone 1 does not ingest, persist, query or present customer telemetry. Collector
reception is verified only for Geordi platform telemetry.

DEFERRED:
- telemetry storage;
- metrics explorer;
- logs explorer;
- trace explorer;
- APM;
- service map;
- alert evaluation;
- Kubernetes;
- AI;
- vendor-specific migration adapters.
