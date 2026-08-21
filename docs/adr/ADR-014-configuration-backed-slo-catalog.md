# ADR-014: Configuration-Backed SLO Definition Catalog

Status: ACCEPTED

## Context

Milestone 7 requires durable SLO definitions, but Geordi currently has no application
persistence layer, database schema, authentication boundary, or authorization model.
Adding mutable REST CRUD would therefore establish several unrelated boundaries at
once: transactional storage, concurrent-write control, crash recovery, backup, and
unauthenticated configuration mutation.

The first milestone needs a small, reproducible definition catalog. It does not need
runtime definition editing, distributed writers, or SLO history.

The following alternatives were considered:

- a version-controlled configuration file loaded by the application;
- a mutable JSON or YAML file written by the backend;
- an embedded or external relational database; and
- storing definitions in VictoriaMetrics, Tempo, or Loki.

## Decision

Use a configuration-backed, read-only SLO definition catalog for Milestone 7.

Definitions are stored in a version-controlled YAML file and mounted read-only into
the backend in the local Compose deployment. The enabled SLO module loads the complete
catalog at startup, validates it before serving requests, and exposes an immutable
in-memory snapshot through an outbound catalog port. The configuration file remains
the durable source of truth; the in-memory snapshot is not persistence.

Catalog validation is all-or-nothing. Duplicate identifiers, invalid definitions, and
more than 50 definitions fail startup rather than publishing a partial catalog. Stable
identifiers belong to the configuration and are not generated again at startup.

Milestone 7 exposes only read operations:

- `GET /api/slos`;
- `GET /api/slos/{id}`; and
- `GET /api/slos/{id}/evaluation`.

There are no POST, PUT, PATCH, or DELETE SLO endpoints. A definition change requires
editing the authoritative YAML file and restarting or redeploying the backend. Dynamic
reload is not supported.

The catalog port is read-only and provider-neutral. YAML binding, Spring configuration,
file locations, and deployment mounts remain adapter/bootstrap concerns and do not enter
the SLO domain or application model.

## Durability and concurrency semantics

- Definitions survive backend process and container recreation because the mounted,
  version-controlled file is authoritative.
- A restart observes either the previous valid file or a newly supplied complete valid
  file; the application never writes partial definitions.
- The loaded catalog is immutable, so concurrent evaluation and list requests require
  no write lock.
- There is no runtime writer, optimistic locking, distributed locking, or multi-writer
  conflict resolution in Milestone 7.
- Deployments with multiple backend instances must provide the same configuration to
  every instance. Geordi does not synchronize divergent files.

## Consequences

Positive:

- durable definitions require no new database or persistence dependency;
- startup validation prevents partially usable or silently corrupt catalogs;
- local and CI definitions are reproducible and reviewable in source control;
- read-only APIs avoid introducing an unauthenticated mutation surface; and
- a future mutable store can replace the configuration adapter behind the catalog port.

Negative:

- operators cannot create or edit definitions in the Milestone 7 UI or REST API;
- changes require a restart or redeployment;
- the file has no independent application-managed backup, audit log, or revision API;
- configuration distribution is an operational responsibility; and
- the 50-definition limit makes this a bounded foundation, not a large-scale SLO
  management plane.

A mutable file was rejected because safe writes require atomic replacement, locking,
conflict behavior, and recovery semantics. A database was rejected as disproportionate
to the current milestone. Telemetry stores were rejected because mutable product
configuration is not telemetry and must not be coupled to a telemetry provider.

