package io.geordi.servicemap.application;

import io.geordi.servicemap.application.port.out.TraceEvidencePort;
import io.geordi.servicemap.domain.CandidateTrace;
import io.geordi.servicemap.domain.DependencyEvidence;
import io.geordi.servicemap.domain.ObservedDependency;
import io.geordi.servicemap.domain.ServiceIdentity;
import io.geordi.servicemap.domain.ServiceMapResult;
import io.geordi.servicemap.domain.SpanKind;
import io.geordi.servicemap.domain.TelemetryOrigin;
import io.geordi.servicemap.domain.TraceEvidenceSpan;
import io.geordi.servicemap.domain.TraceId;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

public final class ServiceMapQueryService {

    private static final int NODE_LIMIT = 50;
    private static final int EDGE_LIMIT = 100;
    private static final int EVIDENCE_LIMIT = 3;
    private static final Comparator<ServiceIdentity> IDENTITY_ORDER = Comparator.comparing(ServiceIdentity::name)
            .thenComparing(identity -> Objects.toString(identity.namespace(), ""))
            .thenComparing(ServiceIdentity::environment);
    private static final Comparator<EdgeKey> EDGE_ORDER = Comparator.comparing(EdgeKey::caller, IDENTITY_ORDER)
            .thenComparing(EdgeKey::callee, IDENTITY_ORDER);
    private static final Comparator<DependencyEvidence> EVIDENCE_ORDER = Comparator
            .comparing(DependencyEvidence::observedAt).reversed()
            .thenComparing(DependencyEvidence::traceId);

    private final TraceEvidencePort evidencePort;

    public ServiceMapQueryService(TraceEvidencePort evidencePort) {
        this.evidencePort = Objects.requireNonNull(evidencePort, "trace evidence port must not be null");
    }

    public ServiceMapResult query(ServiceMapQuery query) {
        Objects.requireNonNull(query, "service map query must not be null");
        var batch = evidencePort.findCandidates(query);
        Map<EdgeKey, Map<TraceId, Instant>> evidenceByEdge = new HashMap<>();
        for (CandidateTrace trace : batch.traces()) {
            collect(trace, query, evidenceByEdge);
        }

        boolean truncated = batch.truncated();
        List<ObservedDependency> edges = new ArrayList<>();
        Set<ServiceIdentity> nodes = new LinkedHashSet<>();
        for (Map.Entry<EdgeKey, Map<TraceId, Instant>> entry : evidenceByEdge.entrySet().stream()
                .sorted(Map.Entry.comparingByKey(EDGE_ORDER)).toList()) {
            List<DependencyEvidence> allEvidence = entry.getValue().entrySet().stream()
                    .map(item -> new DependencyEvidence(item.getKey(), item.getValue()))
                    .sorted(EVIDENCE_ORDER)
                    .toList();
            EdgeKey key = entry.getKey();
            Set<ServiceIdentity> requiredNodes = new LinkedHashSet<>(nodes);
            requiredNodes.add(key.caller());
            requiredNodes.add(key.callee());
            if (edges.size() >= EDGE_LIMIT || requiredNodes.size() > NODE_LIMIT) {
                truncated = true;
                continue;
            }
            nodes.addAll(requiredNodes);
            edges.add(new ObservedDependency(
                    key.caller(), key.callee(), allEvidence.size(), allEvidence.stream().limit(EVIDENCE_LIMIT).toList()));
        }

        List<ServiceIdentity> orderedNodes = nodes.stream().sorted(IDENTITY_ORDER).toList();
        return new ServiceMapResult(query.environment(), query.range(), orderedNodes, edges, truncated);
    }

    private static void collect(
            CandidateTrace trace,
            ServiceMapQuery query,
            Map<EdgeKey, Map<TraceId, Instant>> evidenceByEdge) {
        Map<io.geordi.servicemap.domain.SpanId, TraceEvidenceSpan> spansById = new HashMap<>();
        trace.spans().forEach(span -> spansById.put(span.spanId(), span));
        for (TraceEvidenceSpan server : trace.spans()) {
            if (!qualifyingServer(server, query)) {
                continue;
            }
            TraceEvidenceSpan client = spansById.get(server.parentSpanId());
            if (!qualifyingClient(client, query.environment()) || client.service().equals(server.service())) {
                continue;
            }
            EdgeKey edge = new EdgeKey(client.service(), server.service());
            evidenceByEdge.computeIfAbsent(edge, ignored -> new HashMap<>())
                    .merge(trace.traceId(), server.startTime(), ServiceMapQueryService::latest);
        }
    }

    private static boolean qualifyingServer(TraceEvidenceSpan span, ServiceMapQuery query) {
        return span.kind() == SpanKind.SERVER
                && span.telemetryOrigin() == TelemetryOrigin.MONITORED
                && span.service().environment().equals(query.environment())
                && query.range().contains(span.startTime())
                && span.parentSpanId() != null;
    }

    private static boolean qualifyingClient(TraceEvidenceSpan span, String environment) {
        return span != null
                && span.kind() == SpanKind.CLIENT
                && span.telemetryOrigin() == TelemetryOrigin.MONITORED
                && span.service().environment().equals(environment);
    }

    private static Instant latest(Instant left, Instant right) {
        return left.isAfter(right) ? left : right;
    }

    private record EdgeKey(ServiceIdentity caller, ServiceIdentity callee) {
    }
}
