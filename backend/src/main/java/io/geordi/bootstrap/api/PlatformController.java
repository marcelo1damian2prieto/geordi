package io.geordi.bootstrap.api;

import io.geordi.core.module.ModuleRegistry;
import io.geordi.core.module.ModuleSnapshot;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformHealth;
import io.geordi.core.platform.PlatformIdentity;
import java.util.List;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class PlatformController {

    private final PlatformIdentity identity;
    private final ModuleRegistry moduleRegistry;

    public PlatformController(PlatformIdentity identity, ModuleRegistry moduleRegistry) {
        this.identity = identity;
        this.moduleRegistry = moduleRegistry;
    }

    @GetMapping("/platform")
    PlatformResponse platform() {
        return new PlatformResponse(identity.id(), identity.name(), identity.version());
    }

    @GetMapping("/modules")
    ModulesResponse modules() {
        return new ModulesResponse(toResponses(moduleRegistry.modules()));
    }

    @GetMapping("/platform/health")
    PlatformHealthResponse health() {
        PlatformHealth health = moduleRegistry.health();
        return new PlatformHealthResponse(health.status(), toResponses(health.modules()));
    }

    private static List<ModuleResponse> toResponses(List<ModuleSnapshot> modules) {
        return modules.stream().map(ModuleResponse::from).toList();
    }

    record PlatformResponse(String id, String name, String version) {
    }

    record ModulesResponse(List<ModuleResponse> modules) {
    }

    record PlatformHealthResponse(ModuleStatus status, List<ModuleResponse> modules) {
    }

    record ModuleResponse(String id, String name, boolean enabled, ModuleStatus status) {

        private static ModuleResponse from(ModuleSnapshot snapshot) {
            return new ModuleResponse(snapshot.id(), snapshot.name(), snapshot.enabled(), snapshot.status());
        }
    }
}
