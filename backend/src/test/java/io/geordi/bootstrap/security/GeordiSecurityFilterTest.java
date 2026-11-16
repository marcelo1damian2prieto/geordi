package io.geordi.bootstrap.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.security.jwt.BearerTokenAuthenticator;
import io.geordi.bootstrap.security.oidc.OidcAuthorizationFlow;
import io.geordi.bootstrap.security.session.BoundedSessionStore;
import io.geordi.core.application.security.AuthenticatedPrincipal;
import io.geordi.core.application.security.AuthenticationMechanism;
import io.geordi.core.application.security.GeordiPermission;
import io.geordi.core.application.security.PrincipalIdentity;
import io.geordi.core.application.security.SecurityObservation;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Set;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockFilterChain;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;

class GeordiSecurityFilterTest {
    private static final AuthenticatedPrincipal READ = principal(AuthenticationMechanism.BEARER,
            Set.of(GeordiPermission.OBSERVABILITY_READ));
    private static final AuthenticatedPrincipal EMPTY_SESSION = principal(AuthenticationMechanism.SESSION,
            Set.of(GeordiPermission.ALERT_ACKNOWLEDGE));
    private BoundedSessionStore sessions;
    private SecurityObservation observations;
    private GeordiSecurityFilter filter;

    @BeforeEach
    void setUp() {
        sessions = new BoundedSessionStore(Clock.fixed(Instant.parse("2026-01-02T03:04:05Z"), ZoneOffset.UTC),
                new SecureRandom());
        BearerTokenAuthenticator tokens = token -> "read-token".equals(token) ? READ :
                throwInvalid();
        observations = mock(SecurityObservation.class);
        filter = new GeordiSecurityFilter(new RoutePermissionPolicy(),
                new CredentialSelection(sessions, tokens), sessions, mock(OidcAuthorizationFlow.class),
                new PublicOrigin("https://geordi.example"), observations, new ObjectMapper());
    }

    @Test
    void deniesMissingAndUnlistedRequestsBeforeCallingApplication() throws Exception {
        MockHttpServletResponse unauthenticated = dispatch(request("GET", "/api/platform"));
        assertThat(unauthenticated.getStatus()).isEqualTo(401);
        assertThat(unauthenticated.getContentType()).startsWith("application/problem+json");

        MockHttpServletRequest invalidBearer = request("GET", "/api/platform");
        invalidBearer.addHeader("Authorization", "Bearer invalid-token");
        MockHttpServletResponse invalidResponse = dispatch(invalidBearer);
        assertThat(invalidResponse.getStatus()).isEqualTo(401);
        assertThat(invalidResponse.getHeader("WWW-Authenticate")).isEqualTo("Bearer realm=\"geordi\"");

        MockHttpServletRequest lowercaseBearer = request("GET", "/api/platform");
        lowercaseBearer.addHeader("Authorization", "bEaReR invalid-token");
        MockHttpServletResponse lowercaseResponse = dispatch(lowercaseBearer);
        assertThat(lowercaseResponse.getStatus()).isEqualTo(401);
        assertThat(lowercaseResponse.getHeader("WWW-Authenticate")).isEqualTo("Bearer realm=\"geordi\"");

        MockHttpServletRequest bareBearer = request("GET", "/api/platform");
        bareBearer.addHeader("Authorization", "bEaReR");
        MockHttpServletResponse bareResponse = dispatch(bareBearer);
        assertThat(bareResponse.getStatus()).isEqualTo(401);
        assertThat(bareResponse.getHeader("WWW-Authenticate")).isEqualTo("Bearer realm=\"geordi\"");

        MockHttpServletResponse unknown = dispatch(request("GET", "/api/not-listed"));
        assertThat(unknown.getStatus()).isEqualTo(401);

        MockHttpServletRequest invalidUnknown = request("GET", "/api/not-listed");
        invalidUnknown.addHeader("Authorization", "Bearer invalid-token");
        assertThat(dispatch(invalidUnknown).getStatus()).isEqualTo(401);

        MockHttpServletRequest authenticatedUnknown = request("GET", "/api/not-listed");
        authenticatedUnknown.addHeader("Authorization", "Bearer read-token");
        assertThat(dispatch(authenticatedUnknown).getStatus()).isEqualTo(403);
    }

    @Test
    void rejectsAuthorizationCallbackTransferredToAnotherBrowser() throws Exception {
        String state = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG";
        OidcAuthorizationFlow oidc = mock(OidcAuthorizationFlow.class);
        when(oidc.beginLogin((String) null)).thenReturn(java.net.URI.create(
                "https://auth.example/authorize?state=" + state));
        GeordiSecurityFilter local = new GeordiSecurityFilter(new RoutePermissionPolicy(),
                new CredentialSelection(sessions, token -> throwInvalid()), sessions, oidc,
                new PublicOrigin("https://geordi.example"), observations, new ObjectMapper());
        MockHttpServletResponse login = new MockHttpServletResponse();
        local.doFilter(request("GET", "/oauth2/authorization/geordi"), login, new MockFilterChain());

        assertThat(login.getStatus()).isEqualTo(302);
        assertThat(login.getHeader("Set-Cookie")).contains("__Host-Geordi-OIDC=" + state);

        MockHttpServletRequest transferred = request("GET", "/login/oauth2/code/geordi");
        transferred.addParameter("state", state);
        transferred.addParameter("code", "attacker-code");
        transferred.addHeader("Cookie", "__Host-Geordi-OIDC=" + "A".repeat(43));
        MockHttpServletResponse rejected = dispatch(local, transferred);

        assertThat(rejected.getStatus()).isEqualTo(401);
        assertThat(rejected.getHeaders("Set-Cookie")).anySatisfy(cookie ->
                assertThat(cookie.toString()).contains("__Host-Geordi-OIDC=; Path=/; Max-Age=0"));
        verify(oidc, never()).completeCallback(state, "attacker-code");
    }

    @Test
    void passesOnlyAuthorizedPrincipalToTheApplicationChain() throws Exception {
        MockHttpServletRequest request = request("GET", "/api/platform");
        request.addHeader("Authorization", "Bearer read-token");
        var chain = new MockFilterChain();
        var response = new MockHttpServletResponse();

        filter.doFilter(request, response, chain);

        assertThat(response.getStatus()).isEqualTo(200);
        assertThat(chain.getRequest().getAttribute("geordi.authenticatedPrincipal")).isEqualTo(READ);
        verify(observations).authorization(SecurityObservation.Mechanism.BEARER,
                SecurityObservation.Result.ALLOWED, SecurityObservation.Reason.VALID, SecurityObservation.Endpoint.READ);
    }

    @Test
    void rejectsSessionMutationWithoutCsrfAndWithForeignOriginBeforeTheApplicationChain() throws Exception {
        String sessionId = sessions.createSession(EMPTY_SESSION);
        MockHttpServletRequest missingToken = request("POST", "/api/alert-episodes/episode-1/acknowledgements");
        missingToken.addHeader("Cookie", CredentialSelection.SESSION_COOKIE + "=" + sessionId);
        MockHttpServletResponse missingResponse = dispatch(missingToken);
        assertThat(missingResponse.getStatus()).isEqualTo(403);

        String token = sessions.csrfTokenForSession(sessionId);
        MockHttpServletRequest foreignOrigin = request("POST", "/api/alert-episodes/episode-1/acknowledgements");
        foreignOrigin.addHeader("Cookie", CredentialSelection.SESSION_COOKIE + "=" + sessionId);
        foreignOrigin.addHeader("X-CSRF-TOKEN", token);
        foreignOrigin.addHeader("Origin", "https://attacker.example");
        MockHttpServletResponse originResponse = dispatch(foreignOrigin);
        assertThat(originResponse.getStatus()).isEqualTo(403);
        verify(observations).authorization(SecurityObservation.Mechanism.SESSION,
                SecurityObservation.Result.DENIED, SecurityObservation.Reason.CSRF,
                SecurityObservation.Endpoint.ACKNOWLEDGE);
        verify(observations).authorization(SecurityObservation.Mechanism.SESSION,
                SecurityObservation.Result.DENIED, SecurityObservation.Reason.ORIGIN,
                SecurityObservation.Endpoint.ACKNOWLEDGE);
    }

    @Test
    void meReturnsOnlyCanonicalIdentityAndPermissionsAndHeadHasNoBody() throws Exception {
        AuthenticatedPrincipal operator = new AuthenticatedPrincipal(
                new PrincipalIdentity("https://issuer.example", "subject-7"), "Operator",
                Set.of(GeordiPermission.ALERT_EVALUATE, GeordiPermission.OBSERVABILITY_READ),
                AuthenticationMechanism.BEARER);
        GeordiSecurityFilter local = new GeordiSecurityFilter(new RoutePermissionPolicy(),
                new CredentialSelection(sessions, token -> operator), sessions, mock(OidcAuthorizationFlow.class),
                new PublicOrigin("https://geordi.example"), observations, new ObjectMapper());
        MockHttpServletRequest request = request("HEAD", "/api/me");
        request.addHeader("Authorization", "Bearer read-token");
        var response = new MockHttpServletResponse();

        local.doFilter(request, response, new MockFilterChain());

        assertThat(response.getStatus()).isEqualTo(200);
        assertThat(response.getContentAsByteArray()).isEmpty();
        assertThat(response.getHeader("Cache-Control")).isEqualTo("no-store");
        assertThat(response.getContentLength()).isGreaterThan(0);
    }

    @Test
    void anonymousHealthProbesReachActuatorWithoutAuthentication() throws Exception {
        var chain = new MockFilterChain();
        MockHttpServletRequest request = request("GET", "/actuator/health/liveness");
        var response = new MockHttpServletResponse();

        filter.doFilter(request, response, chain);

        assertThat(chain.getRequest()).isSameAs(request);
        verify(observations).authorization(SecurityObservation.Mechanism.NONE,
                SecurityObservation.Result.ALLOWED, SecurityObservation.Reason.VALID, SecurityObservation.Endpoint.PROBE);
    }

    private MockHttpServletResponse dispatch(MockHttpServletRequest request) throws Exception {
        return dispatch(filter, request);
    }

    private MockHttpServletResponse dispatch(GeordiSecurityFilter target, MockHttpServletRequest request) throws Exception {
        MockHttpServletResponse response = new MockHttpServletResponse();
        target.doFilter(request, response, new MockFilterChain());
        return response;
    }

    private static MockHttpServletRequest request(String method, String path) {
        MockHttpServletRequest request = new MockHttpServletRequest();
        request.setMethod(method);
        request.setRequestURI(path);
        request.setServletPath(path);
        return request;
    }

    private static AuthenticatedPrincipal principal(AuthenticationMechanism mechanism, Set<GeordiPermission> permissions) {
        return new AuthenticatedPrincipal(new PrincipalIdentity("https://issuer.example", "operator-1"), null,
                permissions, mechanism);
    }

    private static AuthenticatedPrincipal throwInvalid() {
        throw SecurityFailure.invalid();
    }
}
