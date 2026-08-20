# Service Map Architecture

Status: IMPLEMENTED; MILESTONE 6 COMPLETE

## Scope

Service Map is a read-only, bounded view of observed monitored
service-to-service dependencies. It derives evidence from existing traces; it is not
telemetry storage, a dependency catalog, configured architecture, or a guarantee of
complete topology.

```text
Available distributed traces
            |
            v
Service Map application <- vendor-neutral dependency evidence port <- trace-store adapter
            |
            v
GET /api/service-map <- React /service-map
            |                         |
            +-- observed nodes -------+-- node -> existing /investigate
            `-- observed edges ---------- edge evidence -> existing /traces
```

Tempo-specific requests, response formats, and parsing remain in its outbound adapter.
The Service Map domain/application exposes neither provider syntax nor provider DTOs.
It has no Logs or Metrics dependency and creates no new store, cache, or persistence.

## Observed-dependency rule

An edge `caller -> callee` requires one available trace containing a direct span
relationship with all of these properties:

- parent span kind is `CLIENT` and its service is the caller;
- child span kind is `SERVER` and its service is the callee;
- the child has the parent span ID as its direct parent;
- both spans are classified `geordi.telemetry.origin=monitored`;
- both identities have service name and environment and their exact environment equals
  the requested environment;
- caller and callee full identities differ; and
- the SERVER span start is in the requested half-open `[from,to)` range.

The canonical identity is `(service.namespace|null, service.name,
deployment.environment.name)`. A missing namespace is exact absence, never a
wildcard. Different namespaces or environments are never collapsed.

Services merely present in the same trace do not create an edge. Same-service internal
relationships do not create self-edges. The initial scope does not infer
`PRODUCER -> CONSUMER` dependencies, remote-parent-only relationships, or span links:
the current canonical trace data does not provide enough verified causal semantics for
them.

## Graph and evidence semantics

Nodes are the distinct canonical endpoints of accepted edges. Edges are directed and
deduplicated by ordered full caller/callee identity. `evidenceCount` is the number of
distinct qualifying trace IDs for that edge; the API returns at most three deterministic
representative trace references. Each reference contains only a trace ID and the
qualifying SERVER start timestamp. It intentionally contains no raw span attributes,
headers, URLs, credentials, or provider payload.

The map has one exact environment and a valid explicit-offset absolute range no wider
than six hours. It represents dependencies observed in available trace telemetry during
that range. Sampling, instrumentation coverage, retention, incomplete traces, and
bounds can omit evidence; absence of an edge does not prove absence of a dependency.

## Bounds and failure behavior

The query first considers at most 50 monitored CLIENT-bearing candidate traces in the
exact environment, requests one additional candidate to detect candidate truncation,
then retrieves canonical details and applies the direct CLIENT-parent-to-SERVER-child
post-filter. It limits concurrent trace retrieval to 8 and has a total 10-second budget.
The returned graph is capped at 50 nodes, 100 edges, and 3 evidence
references per edge. Candidate, node, or edge caps set `truncated=true`; the UI must not
present such a graph as complete. The evidence list is intentionally representative:
`evidenceCount` greater than its length communicates that cap without claiming the
graph itself was truncated.

An empty successful map means no qualifying observed dependencies, not no dependencies.
Invalid context is a client error. Trace-provider unavailable, malformed/partial, and
timeout outcomes remain distinct failures. Service Map does not add a separate provider
probe. Its module status reports activation and evidence-port wiring; runtime provider
health remains the existing Traces module's status, so operators interpret Service Map
availability together with Traces without issuing a second Tempo health request. Existing Metrics,
Traces, Logs, and Service Investigation keep their independent failure behavior.

## Navigation and observability

Node navigation opens existing `/investigate` with the exact node identity and unchanged
absolute range. Edge navigation opens existing trace functionality with a validated
endpoint identity, the unchanged environment/range, and bounded evidence trace IDs; it
does not create another trace detail experience.

Service Map records only low-cardinality platform telemetry for query count, latency,
failure outcome, result-size buckets, and truncation. Service names, trace IDs, span
IDs, raw query values, provider query text, and exception messages are excluded from
metric labels.

## Explicit non-goals

No graph database or persistence; configured/static/CMDB topology; infrastructure,
Kubernetes, host, process, database, broker, external-host, or SaaS nodes; Logs- or
Metrics-derived edges; edge performance analytics; alerts/SLOs; generic graph or
cross-signal engines; eBPF, packet inspection, service-mesh integration, or AI/RCA.
