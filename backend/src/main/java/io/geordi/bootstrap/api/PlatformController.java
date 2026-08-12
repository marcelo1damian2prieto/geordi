package io.geordi.bootstrap.api;

import io.geordi.core.module.ModuleRegistry;
import io.geordi.core.module.ModuleInventory;
import io.geordi.core.module.ModuleSnapshot;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformHealth;
import io.geordi.core.module.PlatformHealthService;
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
    private final PlatformHealthService platformHealthService;

    public PlatformController(
            PlatformIdentity identity,
            ModuleRegistry moduleRegistry,
            PlatformHealthService platformHealthService) {
        this.identity = identity;
        this.moduleRegistry = moduleRegistry;
        this.platformHealthService = platformHealthService;
    }

    @GetMapping("/platform")
    PlatformResponse platform() {
        return new PlatformResponse(identity.id(), identity.name(), identity.version());
    }

    @GetMapping("/modules")
    ModulesResponse modules() {
        return new ModulesResponse(moduleRegistry.modules().stream().map(ModuleResponse::from).toList());
    }

    @GetMapping("/platform/health")
    PlatformHealthResponse health() {
        PlatformHealth health = platformHealthService.health();
        return new PlatformHealthResponse(health.status(), toHealthResponses(health.modules()));
    }

    private static List<ModuleHealthResponse> toHealthResponses(List<ModuleSnapshot> modules) {
        return modules.stream().map(ModuleHealthResponse::from).toList();
    }

    record PlatformResponse(String id, String name, String version) {
    }

    record ModulesResponse(List<ModuleResponse> modules) {
    }

    record PlatformHealthResponse(ModuleStatus status, List<ModuleHealthResponse> modules) {
    }

    record ModuleResponse(String id, String name, boolean enabled) {

        private static ModuleResponse from(ModuleInventory inventory) {
            return new ModuleResponse(inventory.id(), inventory.name(), inventory.enabled());
        }
    }

    record ModuleHealthResponse(String id, String name, boolean enabled, ModuleStatus status) {

        private static ModuleHealthResponse from(ModuleSnapshot snapshot) {
            return new ModuleHealthResponse(snapshot.id(), snapshot.name(), snapshot.enabled(), snapshot.status());
        }
    }
}
