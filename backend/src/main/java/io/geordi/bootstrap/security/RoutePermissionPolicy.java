package io.geordi.bootstrap.security;

import io.geordi.core.application.security.GeordiPermission;
import java.util.Optional;
import java.util.regex.Pattern;

/** Closed method/path inventory; unmatched routes are denied by the caller. */
public final class RoutePermissionPolicy {
    private static final Pattern ENCODED_SEPARATOR = Pattern.compile("(?i)%2f|%5c|%2e");
    private static final String ID = "[^/]+";

    public enum Endpoint { READ, ACKNOWLEDGE, EVALUATE, ME, LOGIN, CALLBACK, CSRF, LOGOUT, PROBE, DENIED }

    public record Requirement(Endpoint endpoint, GeordiPermission permission,
            boolean anonymous, boolean sessionOnly) { }

    public Optional<Requirement> resolve(String method, String path) {
        if (method == null || path == null || path.contains("\\") || path.contains("//")
                || ENCODED_SEPARATOR.matcher(path).find() || path.endsWith("/")) return Optional.empty();
        if ("GET".equals(method) || "HEAD".equals(method)) {
            if (is(path, "/actuator/health/liveness", "/actuator/health/readiness")) {
                return Optional.of(new Requirement(Endpoint.PROBE, null, true, false));
            }
            if ("/api/me".equals(path)) return Optional.of(new Requirement(Endpoint.ME, null, false, false));
            if ("/api/auth/csrf".equals(path) && "GET".equals(method)) {
                return Optional.of(new Requirement(Endpoint.CSRF, null, false, true));
            }
            if ("GET".equals(method) && "/oauth2/authorization/geordi".equals(path)) {
                return Optional.of(new Requirement(Endpoint.LOGIN, null, true, false));
            }
            if ("GET".equals(method) && "/login/oauth2/code/geordi".equals(path)) {
                return Optional.of(new Requirement(Endpoint.CALLBACK, null, true, false));
            }
            if ("/actuator/health".equals(path)) {
                return read(Endpoint.READ);
            }
            if (matches(path, "/api/platform", "/api/modules", "/api/platform/health", "/api/metrics/services",
                    "/api/metrics/overview", "/api/metrics/series", "/api/traces/services", "/api/traces",
                    "/api/logs/services", "/api/logs", "/api/service-map", "/api/slos", "/api/alert-policies",
                    "/api/alert-states", "/api/alert-episodes", "/api/alert-transitions")) return read(Endpoint.READ);
            if (segment(path, "/api/traces/" + ID) || segment(path, "/api/slos/" + ID)
                    || segment(path, "/api/slos/" + ID + "/evaluation")
                    || segment(path, "/api/alert-policies/" + ID + "/evaluation")
                    || segment(path, "/api/alert-episodes/" + ID)) return read(Endpoint.READ);
        }
        if ("POST".equals(method)) {
            if (segment(path, "/api/alert-episodes/" + ID + "/acknowledgements")) {
                return Optional.of(new Requirement(Endpoint.ACKNOWLEDGE,
                        GeordiPermission.ALERT_ACKNOWLEDGE, false, false));
            }
            if (segment(path, "/api/alert-policies/" + ID + "/lifecycle-evaluations")) {
                return Optional.of(new Requirement(Endpoint.EVALUATE,
                        GeordiPermission.ALERT_EVALUATE, false, false));
            }
            if ("/api/auth/logout".equals(path)) {
                return Optional.of(new Requirement(Endpoint.LOGOUT, null, false, true));
            }
        }
        return Optional.empty();
    }

    private static Optional<Requirement> read(Endpoint endpoint) {
        return Optional.of(new Requirement(endpoint, GeordiPermission.OBSERVABILITY_READ, false, false));
    }

    private static boolean is(String path, String first, String second) {
        return first.equals(path) || second.equals(path);
    }

    private static boolean matches(String path, String... candidates) {
        for (String candidate : candidates) if (candidate.equals(path)) return true;
        return false;
    }

    private static boolean segment(String path, String pattern) {
        return path.matches(pattern);
    }
}
