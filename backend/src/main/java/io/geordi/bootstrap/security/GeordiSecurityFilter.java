package io.geordi.bootstrap.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.security.oidc.OidcAuthorizationFlow;
import io.geordi.bootstrap.security.oidc.OidcBrowserBinding;
import io.geordi.bootstrap.security.session.BoundedSessionStore;
import io.geordi.core.application.security.AuthenticatedPrincipal;
import io.geordi.core.application.security.AuthenticationMechanism;
import io.geordi.core.application.security.SecurityObservation;
import jakarta.servlet.DispatcherType;
import jakarta.servlet.Filter;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.ServletRequest;
import jakarta.servlet.ServletResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;

/** Default-deny servlet ingress for exact M19 routes and bounded protocol endpoints. */
public final class GeordiSecurityFilter implements Filter {
    private final RoutePermissionPolicy routes;
    private final CredentialSelection credentials;
    private final BoundedSessionStore sessions;
    private final OidcAuthorizationFlow oidc;
    private final PublicOrigin publicOrigin;
    private final SecurityObservation observations;
    private final ObjectMapper json;

    public GeordiSecurityFilter(RoutePermissionPolicy routes, CredentialSelection credentials,
            BoundedSessionStore sessions, OidcAuthorizationFlow oidc, PublicOrigin publicOrigin,
            SecurityObservation observations, ObjectMapper json) {
        this.routes = Objects.requireNonNull(routes);
        this.credentials = Objects.requireNonNull(credentials);
        this.sessions = Objects.requireNonNull(sessions);
        this.oidc = Objects.requireNonNull(oidc);
        this.publicOrigin = Objects.requireNonNull(publicOrigin);
        this.observations = Objects.requireNonNull(observations);
        this.json = Objects.requireNonNull(json);
    }

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        HttpServletRequest http = (HttpServletRequest) request;
        HttpServletResponse output = (HttpServletResponse) response;
        String path = http.getRequestURI();
        String contextPath = http.getContextPath();
        if (!contextPath.isEmpty() && path.startsWith(contextPath)) path = path.substring(contextPath.length());
        var requirement = routes.resolve(http.getMethod(), path);
        if (http.getDispatcherType() == DispatcherType.ERROR) {
            problem(output, HttpServletResponse.SC_NOT_FOUND, "Not found", "The requested resource is unavailable.");
            return;
        }
        CredentialSelection.SelectedCredential selected;
        try {
            selected = credentials.select(http.getHeaders("Authorization"), http.getHeaders("Cookie"));
        } catch (SecurityFailure failure) {
            observeAuthenticationFailure(http, endpoint(requirement), failure);
            if (status(failure) == HttpServletResponse.SC_UNAUTHORIZED
                    && bearerScheme(http.getHeader(HttpHeaders.AUTHORIZATION))) {
                output.setHeader(HttpHeaders.WWW_AUTHENTICATE, "Bearer realm=\"geordi\"");
            }
            securityProblem(output, failure);
            return;
        }

        if (requirement.isEmpty()) {
            if (!selected.authenticated()) {
                SecurityFailure failure = new SecurityFailure(SecurityFailure.Kind.INVALID_AUTHENTICATION);
                observeAuthenticationFailure(http, RoutePermissionPolicy.Endpoint.DENIED, failure);
                if (bearerScheme(http.getHeader(HttpHeaders.AUTHORIZATION))) {
                    output.setHeader(HttpHeaders.WWW_AUTHENTICATE, "Bearer realm=\"geordi\"");
                }
                securityProblem(output, failure);
                return;
            }
            observations.authorization(mechanism(selected.principal()), SecurityObservation.Result.DENIED,
                    SecurityObservation.Reason.ROUTE, SecurityObservation.Endpoint.DENIED);
            problem(output, HttpServletResponse.SC_FORBIDDEN, "Forbidden", "The requested operation is not permitted.");
            return;
        }

        RoutePermissionPolicy.Requirement route = requirement.get();

        if (route.anonymous()) {
            if (route.endpoint() == RoutePermissionPolicy.Endpoint.PROBE && selected.authenticated()) {
                observations.authentication(mechanism(selected.principal()), SecurityObservation.Result.SUCCESS,
                        SecurityObservation.Reason.VALID, observationEndpoint(route.endpoint()));
            }
            handlePublicProtocol(http, output, route, selected, chain);
            return;
        }
        AuthenticatedPrincipal principal = selected.principal();
        if (principal == null) {
            observations.authentication(SecurityObservation.Mechanism.NONE, SecurityObservation.Result.FAILURE,
                    SecurityObservation.Reason.MISSING, observationEndpoint(route.endpoint()));
            output.setHeader(HttpHeaders.WWW_AUTHENTICATE, "Bearer realm=\"geordi\"");
            problem(output, HttpServletResponse.SC_UNAUTHORIZED, "Authentication required",
                    "Authentication is required to access this resource.");
            return;
        }
        observations.authentication(mechanism(principal), SecurityObservation.Result.SUCCESS,
                SecurityObservation.Reason.VALID, observationEndpoint(route.endpoint()));
        if (route.sessionOnly() && principal.mechanism() != AuthenticationMechanism.SESSION) {
            deny(output, principal, route.endpoint(), SecurityObservation.Reason.PERMISSION);
            return;
        }
        if (route.permission() != null && !principal.permissions().contains(route.permission())) {
            deny(output, principal, route.endpoint(), SecurityObservation.Reason.PERMISSION);
            return;
        }
        boolean mutation = "POST".equals(http.getMethod());
        if (mutation && http.getHeader(HttpHeaders.ORIGIN) != null) {
            try {
                publicOrigin.requireMatching(http.getHeader(HttpHeaders.ORIGIN));
            } catch (SecurityFailure failure) {
                deny(output, principal, route.endpoint(), SecurityObservation.Reason.ORIGIN);
                return;
            }
        }
        if (mutation && principal.mechanism() == AuthenticationMechanism.SESSION
                && !sessions.hasValidCsrfToken(selected.sessionId(), http.getHeader("X-CSRF-TOKEN"))) {
            deny(output, principal, route.endpoint(), SecurityObservation.Reason.CSRF);
            return;
        }
        observations.authorization(mechanism(principal), SecurityObservation.Result.ALLOWED,
                SecurityObservation.Reason.VALID, observationEndpoint(route.endpoint()));

        http.setAttribute("geordi.authenticatedPrincipal", principal);
        http.setAttribute("geordi.sessionId", selected.sessionId());
        if (route.endpoint() == RoutePermissionPolicy.Endpoint.ME) {
            me(output, http.getMethod(), principal);
            return;
        }
        if (route.endpoint() == RoutePermissionPolicy.Endpoint.CSRF) {
            csrf(output, selected.sessionId());
            return;
        }
        if (route.endpoint() == RoutePermissionPolicy.Endpoint.LOGOUT) {
            sessions.logout(selected.sessionId());
            output.setHeader(HttpHeaders.SET_COOKIE, sessionCookie("", true));
            output.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
            output.setStatus(HttpServletResponse.SC_NO_CONTENT);
            return;
        }
        chain.doFilter(request, response);
    }

    private static RoutePermissionPolicy.Endpoint endpoint(
            java.util.Optional<RoutePermissionPolicy.Requirement> requirement) {
        return requirement.map(RoutePermissionPolicy.Requirement::endpoint)
                .orElse(RoutePermissionPolicy.Endpoint.DENIED);
    }

    private void handlePublicProtocol(HttpServletRequest request, HttpServletResponse response,
            RoutePermissionPolicy.Requirement route, CredentialSelection.SelectedCredential selected,
            FilterChain chain) throws IOException, ServletException {
        try {
            if (route.endpoint() == RoutePermissionPolicy.Endpoint.PROBE) {
                observations.authorization(SecurityObservation.Mechanism.NONE, SecurityObservation.Result.ALLOWED,
                        SecurityObservation.Reason.VALID, observationEndpoint(route.endpoint()));
                response.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
                chain.doFilter(request, response);
                return;
            }
            if (route.endpoint() == RoutePermissionPolicy.Endpoint.LOGIN) {
                var prior = selected.principal() != null
                        && selected.principal().mechanism() == AuthenticationMechanism.SESSION
                                ? selected.sessionId() : null;
                response.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
                URI authorizationUri = oidc.beginLogin(prior);
                String state = OidcBrowserBinding.stateFromAuthorizationUri(authorizationUri);
                response.addHeader(HttpHeaders.SET_COOKIE, OidcBrowserBinding.cookie(state));
                response.setHeader(HttpHeaders.LOCATION, authorizationUri.toASCIIString());
                response.setStatus(HttpServletResponse.SC_FOUND);
                observations.authorization(mechanism(selected.principal()), SecurityObservation.Result.ALLOWED,
                        SecurityObservation.Reason.VALID, observationEndpoint(route.endpoint()));
                return;
            }
            if (route.endpoint() == RoutePermissionPolicy.Endpoint.CALLBACK) {
                String[] states = request.getParameterValues("state");
                String[] codes = request.getParameterValues("code");
                String state = states != null && states.length == 1 ? states[0] : null;
                String code = codes != null && codes.length == 1 ? codes[0] : null;
                try {
                    OidcBrowserBinding.requireCookie(request.getHeaders(HttpHeaders.COOKIE), state);
                } finally {
                    response.addHeader(HttpHeaders.SET_COOKIE, OidcBrowserBinding.clearCookie());
                }
                String sessionId = oidc.completeCallback(state, code);
                response.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
                response.addHeader(HttpHeaders.SET_COOKIE, sessionCookie(sessionId, false));
                response.setHeader(HttpHeaders.LOCATION, publicOrigin.value() + "/");
                response.setStatus(HttpServletResponse.SC_FOUND);
                observations.authentication(SecurityObservation.Mechanism.SESSION, SecurityObservation.Result.SUCCESS,
                        SecurityObservation.Reason.VALID, observationEndpoint(route.endpoint()));
                return;
            }
            problem(response, HttpServletResponse.SC_NOT_FOUND, "Not found", "The requested resource is unavailable.");
        } catch (SecurityFailure failure) {
            securityProblem(response, failure);
            observations.authorization(mechanism(selected.principal()), SecurityObservation.Result.DENIED,
                    reason(failure), observationEndpoint(route.endpoint()));
        }
    }

    private void me(HttpServletResponse response, String method, AuthenticatedPrincipal principal) throws IOException {
        List<String> permissionNames = principal.permissions().stream().map(value -> value.publicName()).sorted().toList();
        byte[] body = json.writeValueAsBytes(new IdentityResponse(principal.identity().issuer(),
                principal.identity().subject(), principal.displayName(), permissionNames, principal.mechanism().name()));
        response.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
        response.setContentType(MediaType.APPLICATION_JSON_VALUE);
        response.setContentLength(body.length);
        response.setStatus(HttpServletResponse.SC_OK);
        if (!"HEAD".equals(method)) response.getOutputStream().write(body);
    }

    private void csrf(HttpServletResponse response, String sessionId) throws IOException {
        try {
            String token = sessions.csrfTokenForSession(sessionId);
            byte[] body = json.writeValueAsBytes(Map.of("headerName", "X-CSRF-TOKEN", "token", token));
            response.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
            response.setContentType(MediaType.APPLICATION_JSON_VALUE);
            response.getOutputStream().write(body);
        } catch (SecurityFailure failure) {
            securityProblem(response, failure);
        }
    }

    private void deny(HttpServletResponse response, AuthenticatedPrincipal principal,
            RoutePermissionPolicy.Endpoint endpoint, SecurityObservation.Reason reason) throws IOException {
        observations.authorization(mechanism(principal), SecurityObservation.Result.DENIED, reason, observationEndpoint(endpoint));
        problem(response, HttpServletResponse.SC_FORBIDDEN, "Forbidden", "You are not allowed to perform this operation.");
    }

    private void observeAuthenticationFailure(HttpServletRequest request, RoutePermissionPolicy.Endpoint endpoint,
            SecurityFailure failure) {
        SecurityObservation.Mechanism mechanism = failure.kind() == SecurityFailure.Kind.AMBIGUOUS_CREDENTIALS
                ? SecurityObservation.Mechanism.AMBIGUOUS
                : request.getHeader(HttpHeaders.AUTHORIZATION) != null ? SecurityObservation.Mechanism.BEARER
                        : SecurityObservation.Mechanism.NONE;
        observations.authentication(mechanism, SecurityObservation.Result.FAILURE, reason(failure), observationEndpoint(endpoint));
    }

    private void problem(HttpServletResponse response, int status, String title, String detail) throws IOException {
        byte[] body = json.writeValueAsBytes(Map.of("type", "about:blank", "title", title, "status", status, "detail", detail));
        response.resetBuffer();
        response.setStatus(status);
        response.setContentType("application/problem+json");
        response.setCharacterEncoding(StandardCharsets.UTF_8.name());
        response.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
        response.setHeader(HttpHeaders.PRAGMA, "no-cache");
        if (status == HttpServletResponse.SC_SERVICE_UNAVAILABLE) response.setHeader(HttpHeaders.RETRY_AFTER, "1");
        response.setContentLength(body.length);
        response.getOutputStream().write(body);
    }

    private void securityProblem(HttpServletResponse response, SecurityFailure failure) throws IOException {
        problem(response, status(failure), title(failure), detail(failure));
        if (failure.kind() == SecurityFailure.Kind.CAPACITY_EXHAUSTED) {
            response.setHeader(HttpHeaders.RETRY_AFTER, "30");
        }
    }

    private static String sessionCookie(String value, boolean clear) {
        return CredentialSelection.SESSION_COOKIE + "=" + value + "; Path=/; Max-Age=" + (clear ? "0" : "3600")
                + "; Secure; HttpOnly; SameSite=Lax";
    }

    private static int status(SecurityFailure failure) {
        return switch (failure.kind()) {
            case INVALID_AUTHENTICATION -> HttpServletResponse.SC_UNAUTHORIZED;
            case AMBIGUOUS_CREDENTIALS -> HttpServletResponse.SC_BAD_REQUEST;
            case DEPENDENCY_UNAVAILABLE, CAPACITY_EXHAUSTED -> HttpServletResponse.SC_SERVICE_UNAVAILABLE;
            case FORBIDDEN, CSRF, ORIGIN -> HttpServletResponse.SC_FORBIDDEN;
            case DENIED -> HttpServletResponse.SC_NOT_FOUND;
        };
    }

    private static boolean bearerScheme(String authorization) {
        if (authorization == null) return false;
        String value = authorization.stripLeading();
        int separator = value.indexOf(' ');
        int tab = value.indexOf('\t');
        if (separator < 0 || tab >= 0 && tab < separator) separator = tab;
        String scheme = separator < 0 ? value : value.substring(0, separator);
        return "Bearer".equalsIgnoreCase(scheme);
    }

    private static String title(SecurityFailure failure) {
        return switch (status(failure)) {
            case HttpServletResponse.SC_UNAUTHORIZED -> "Authentication failed";
            case HttpServletResponse.SC_BAD_REQUEST -> "Invalid request";
            case HttpServletResponse.SC_FORBIDDEN -> "Forbidden";
            case HttpServletResponse.SC_SERVICE_UNAVAILABLE -> "Security service unavailable";
            default -> "Not found";
        };
    }

    private static String detail(SecurityFailure failure) {
        return switch (status(failure)) {
            case HttpServletResponse.SC_UNAUTHORIZED -> "Authentication is required to access this resource.";
            case HttpServletResponse.SC_BAD_REQUEST -> "The request contains ambiguous credentials.";
            case HttpServletResponse.SC_FORBIDDEN -> "You are not allowed to perform this operation.";
            case HttpServletResponse.SC_SERVICE_UNAVAILABLE -> "The requested operation could not be completed.";
            default -> "The requested resource is unavailable.";
        };
    }

    private static SecurityObservation.Reason reason(SecurityFailure failure) {
        return switch (failure.kind()) {
            case INVALID_AUTHENTICATION -> SecurityObservation.Reason.INVALID;
            case DEPENDENCY_UNAVAILABLE -> SecurityObservation.Reason.DEPENDENCY;
            case AMBIGUOUS_CREDENTIALS -> SecurityObservation.Reason.AMBIGUOUS;
            case CAPACITY_EXHAUSTED -> SecurityObservation.Reason.CAPACITY;
            case CSRF -> SecurityObservation.Reason.CSRF;
            case ORIGIN -> SecurityObservation.Reason.ORIGIN;
            case FORBIDDEN -> SecurityObservation.Reason.PERMISSION;
            case DENIED -> SecurityObservation.Reason.ROUTE;
        };
    }

    private static SecurityObservation.Mechanism mechanism(AuthenticatedPrincipal principal) {
        if (principal == null) return SecurityObservation.Mechanism.NONE;
        return principal.mechanism() == AuthenticationMechanism.SESSION
                ? SecurityObservation.Mechanism.SESSION : SecurityObservation.Mechanism.BEARER;
    }

    private static SecurityObservation.Endpoint observationEndpoint(RoutePermissionPolicy.Endpoint endpoint) {
        return SecurityObservation.Endpoint.valueOf(endpoint.name());
    }

    private record IdentityResponse(String issuer, String subject, String displayName,
            List<String> permissions, String authMode) { }
}
