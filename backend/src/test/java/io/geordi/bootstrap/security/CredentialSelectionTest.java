package io.geordi.bootstrap.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;

import io.geordi.bootstrap.security.jwt.BearerTokenAuthenticator;
import io.geordi.bootstrap.security.session.BoundedSessionStore;
import io.geordi.core.application.security.AuthenticatedPrincipal;
import io.geordi.core.application.security.AuthenticationMechanism;
import io.geordi.core.application.security.PrincipalIdentity;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Collections;
import java.util.Enumeration;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;

class CredentialSelectionTest {
    private static final AuthenticatedPrincipal SESSION = new AuthenticatedPrincipal(
            new PrincipalIdentity("https://issuer.example", "session-subject"), null, Set.of(), AuthenticationMechanism.SESSION);
    private static final AuthenticatedPrincipal BEARER = new AuthenticatedPrincipal(
            new PrincipalIdentity("https://issuer.example", "bearer-subject"), null, Set.of(), AuthenticationMechanism.BEARER);

    @Test
    void selectsSessionAndBearerWithoutMergingAndIgnoresUnknownCookieForBearer() {
        BoundedSessionStore sessions = sessions();
        String sessionId = sessions.createSession(SESSION);
        BearerTokenAuthenticator bearer = token -> BEARER;
        CredentialSelection selector = new CredentialSelection(sessions, bearer);

        var fromSession = selector.select(headers(), headers("__Host-GEORDISESSION=" + sessionId));
        var fromBearer = selector.select(headers("Bearer signed-token"), headers("__Host-GEORDISESSION=unknown"));
        var anonymous = selector.select(headers(), headers("__Host-GEORDISESSION=unknown"));

        assertThat(fromSession.principal()).isEqualTo(SESSION);
        assertThat(fromSession.sessionId()).isEqualTo(sessionId);
        assertThat(fromBearer.principal()).isEqualTo(BEARER);
        assertThat(fromBearer.sessionId()).isNull();
        assertThat(anonymous.authenticated()).isFalse();
    }

    @Test
    void rejectsRepeatedCoalescedAndMixedCredentialsBeforeBearerValidation() {
        BoundedSessionStore sessions = sessions();
        String id = sessions.createSession(SESSION);
        BearerTokenAuthenticator bearer = mock(BearerTokenAuthenticator.class);
        CredentialSelection selector = new CredentialSelection(sessions, bearer);

        assertAmbiguous(() -> selector.select(headers("Bearer a", "Bearer b"), headers()));
        assertAmbiguous(() -> selector.select(headers("Bearer a, Bearer b"), headers()));
        assertAmbiguous(() -> selector.select(headers("Bearer a"), headers("__Host-GEORDISESSION=" + id)));
        assertAmbiguous(() -> selector.select(headers(), headers(
                "__Host-GEORDISESSION=" + id, "__Host-GEORDISESSION=" + id)));
        verify(bearer, never()).authenticate(org.mockito.ArgumentMatchers.anyString());
    }

    @Test
    void invalidBearerNeverFallsBackToAnUnknownOrExpiredCookie() {
        BoundedSessionStore sessions = sessions();
        CredentialSelection selector = new CredentialSelection(sessions, token -> {
            throw SecurityFailure.invalid();
        });
        assertThatThrownBy(() -> selector.select(headers("Bearer invalid"), headers("__Host-GEORDISESSION=expired")))
                .isInstanceOf(SecurityFailure.class)
                .satisfies(failure -> assertThat(((SecurityFailure) failure).kind())
                        .isEqualTo(SecurityFailure.Kind.INVALID_AUTHENTICATION));
    }

    @Test
    void rejectsUnsupportedAuthorizationSchemeAndOversizedBearerBeforeParsing() {
        BearerTokenAuthenticator bearer = mock(BearerTokenAuthenticator.class);
        CredentialSelection selector = new CredentialSelection(sessions(), bearer);
        assertInvalid(() -> selector.select(headers("Basic dXNlcjpwYXNz"), headers()));
        assertInvalid(() -> selector.select(headers("Bearer " + "x".repeat(16 * 1024 + 1)), headers()));
        verify(bearer, never()).authenticate(org.mockito.ArgumentMatchers.anyString());
    }

    private static BoundedSessionStore sessions() {
        return new BoundedSessionStore(Clock.fixed(Instant.parse("2026-01-02T03:04:05Z"), ZoneOffset.UTC), new SecureRandom());
    }

    private static Enumeration<String> headers(String... values) {
        return Collections.enumeration(List.of(values));
    }

    private static void assertAmbiguous(Runnable operation) {
        assertThatThrownBy(operation::run).isInstanceOf(SecurityFailure.class)
                .satisfies(failure -> assertThat(((SecurityFailure) failure).kind())
                        .isEqualTo(SecurityFailure.Kind.AMBIGUOUS_CREDENTIALS));
    }

    private static void assertInvalid(Runnable operation) {
        assertThatThrownBy(operation::run).isInstanceOf(SecurityFailure.class)
                .satisfies(failure -> assertThat(((SecurityFailure) failure).kind())
                        .isEqualTo(SecurityFailure.Kind.INVALID_AUTHENTICATION));
    }
}
