package io.geordi.bootstrap.security;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.core.application.security.GeordiPermission;
import java.util.List;
import org.junit.jupiter.api.Test;

class RoutePermissionPolicyTest {
    private final RoutePermissionPolicy policy = new RoutePermissionPolicy();

    @Test
    void mapsEveryFrozenApplicationReadAndHeadToReadPermission() {
        List<String> reads = List.of("/api/platform", "/api/modules", "/api/platform/health", "/api/metrics/services",
                "/api/metrics/overview", "/api/metrics/series", "/api/traces/services", "/api/traces",
                "/api/traces/trace-1", "/api/logs/services", "/api/logs", "/api/service-map", "/api/slos",
                "/api/slos/slo-1", "/api/slos/slo-1/evaluation", "/api/alert-policies",
                "/api/alert-policies/policy-1/evaluation", "/api/alert-states", "/api/alert-episodes",
                "/api/alert-episodes/episode-1", "/api/alert-transitions", "/actuator/health");
        for (String path : reads) {
            assertRequirement("GET", path, GeordiPermission.OBSERVABILITY_READ);
            assertRequirement("HEAD", path, GeordiPermission.OBSERVABILITY_READ);
        }
        assertThat(reads).hasSize(22); // 21 application GET operations plus detailed health.
    }

    @Test
    void separatesMutationPermissionsAndKeepsProtocolMethodsExact() {
        assertRequirement("POST", "/api/alert-episodes/episode-1/acknowledgements",
                GeordiPermission.ALERT_ACKNOWLEDGE);
        assertRequirement("POST", "/api/alert-policies/policy-1/lifecycle-evaluations",
                GeordiPermission.ALERT_EVALUATE);
        assertThat(policy.resolve("GET", "/api/me").orElseThrow().permission()).isNull();
        assertThat(policy.resolve("GET", "/api/auth/csrf").orElseThrow().sessionOnly()).isTrue();
        assertThat(policy.resolve("POST", "/api/auth/logout").orElseThrow().sessionOnly()).isTrue();
        assertThat(policy.resolve("GET", "/actuator/health/liveness").orElseThrow().anonymous()).isTrue();
        assertThat(policy.resolve("HEAD", "/actuator/health/readiness").orElseThrow().anonymous()).isTrue();
        assertThat(policy.resolve("GET", "/oauth2/authorization/geordi").orElseThrow().anonymous()).isTrue();
        assertThat(policy.resolve("POST", "/oauth2/authorization/geordi")).isEmpty();
        assertThat(policy.resolve("HEAD", "/login/oauth2/code/geordi")).isEmpty();
        assertThat(policy.resolve("HEAD", "/api/auth/csrf")).isEmpty();
    }

    @Test
    void deniesUnlistedPathsMethodsAndAmbiguousPathSpellings() {
        for (var request : List.of(
                new String[] {"GET", "/api/unknown"}, new String[] {"GET", "/error"},
                new String[] {"GET", "/actuator/health/components"}, new String[] {"GET", "/api/me/"},
                new String[] {"OPTIONS", "/api/platform"}, new String[] {"PUT", "/api/alert-episodes/episode-1"},
                new String[] {"POST", "/api/platform"}, new String[] {"GET", "/api//platform"},
                new String[] {"GET", "/api/alert-episodes/a%2Fb"}, new String[] {"TRACE", "/api/me"})) {
            assertThat(policy.resolve(request[0], request[1])).as("%s %s", request[0], request[1]).isEmpty();
        }
    }

    private void assertRequirement(String method, String path, GeordiPermission permission) {
        var requirement = policy.resolve(method, path).orElseThrow();
        assertThat(requirement.permission()).isEqualTo(permission);
        assertThat(requirement.anonymous()).isFalse();
        assertThat(requirement.endpoint()).isNotNull();
    }
}
