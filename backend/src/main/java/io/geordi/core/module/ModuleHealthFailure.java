package io.geordi.core.module;

import java.util.Objects;

public record ModuleHealthFailure(String moduleId, RuntimeException cause) {

    public ModuleHealthFailure {
        Objects.requireNonNull(moduleId, "module id must not be null");
        Objects.requireNonNull(cause, "failure cause must not be null");
    }
}
