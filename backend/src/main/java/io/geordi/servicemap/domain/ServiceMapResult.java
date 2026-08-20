package io.geordi.servicemap.domain;

import java.util.List;
import java.util.Objects;

public record ServiceMapResult(
        String environment,
        TimeRange range,
        List<ServiceIdentity> nodes,
        List<ObservedDependency> edges,
        boolean truncated) {

    public ServiceMapResult {
        if (environment == null || environment.isBlank()) {
            throw new IllegalArgumentException("environment must not be blank");
        }
        environment = environment.trim();
        Objects.requireNonNull(range, "range must not be null");
        nodes = List.copyOf(Objects.requireNonNull(nodes, "nodes must not be null"));
        edges = List.copyOf(Objects.requireNonNull(edges, "edges must not be null"));
        if (nodes.size() > 50 || edges.size() > 100) {
            throw new IllegalArgumentException("service map exceeds graph bounds");
        }
    }
}
