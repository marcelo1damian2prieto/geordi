package io.geordi.servicemap.domain;

import java.util.List;
import java.util.Objects;

public record ObservedDependency(
        ServiceIdentity caller,
        ServiceIdentity callee,
        int evidenceCount,
        List<DependencyEvidence> evidence) {

    public ObservedDependency {
        Objects.requireNonNull(caller, "caller must not be null");
        Objects.requireNonNull(callee, "callee must not be null");
        evidence = List.copyOf(Objects.requireNonNull(evidence, "evidence must not be null"));
        if (caller.equals(callee) || evidenceCount < 1 || evidence.isEmpty()
                || evidence.size() > 3 || evidence.size() > evidenceCount) {
            throw new IllegalArgumentException("observed dependency is invalid");
        }
    }
}
