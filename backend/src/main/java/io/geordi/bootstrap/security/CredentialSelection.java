package io.geordi.bootstrap.security;

import io.geordi.bootstrap.security.jwt.BearerTokenAuthenticator;
import io.geordi.bootstrap.security.session.BoundedSessionStore;
import io.geordi.core.application.security.AuthenticatedPrincipal;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;

/** Enforces deterministic session/bearer selection before route policy or body parsing. */
public final class CredentialSelection {
    public static final String SESSION_COOKIE = "__Host-GEORDISESSION";
    private static final String BEARER_PREFIX = "Bearer ";
    private final BoundedSessionStore sessions;
    private final BearerTokenAuthenticator bearerTokens;

    public CredentialSelection(BoundedSessionStore sessions, BearerTokenAuthenticator bearerTokens) {
        this.sessions = sessions;
        this.bearerTokens = bearerTokens;
    }

    public SelectedCredential select(Enumeration<String> authorizationHeaders,
            Enumeration<String> cookieHeaders) {
        List<String> authorization = values(authorizationHeaders);
        List<String> cookies = values(cookieHeaders);
        if (authorization.size() > 1 || authorization.stream().anyMatch(value -> value.indexOf(',') >= 0)) {
            throw new SecurityFailure(SecurityFailure.Kind.AMBIGUOUS_CREDENTIALS);
        }
        String sessionId = sessionCookie(cookies);
        AuthenticatedPrincipal sessionPrincipal = sessions.peek(sessionId);
        boolean hasAuthorization = !authorization.isEmpty();
        if (sessionPrincipal != null && hasAuthorization) {
            throw new SecurityFailure(SecurityFailure.Kind.AMBIGUOUS_CREDENTIALS);
        }
        if (hasAuthorization) {
            String value = authorization.getFirst();
            if (!value.regionMatches(true, 0, BEARER_PREFIX, 0, BEARER_PREFIX.length())
                    || value.length() == BEARER_PREFIX.length()
                    || value.length() > 16 * 1024 + BEARER_PREFIX.length()) throw SecurityFailure.invalid();
            String token = value.substring(BEARER_PREFIX.length());
            if (token.charAt(0) == ' ' || token.charAt(token.length() - 1) == ' ') throw SecurityFailure.invalid();
            return new SelectedCredential(bearerTokens.authenticate(token), null);
        }
        if (sessionPrincipal != null) {
            AuthenticatedPrincipal touched = sessions.resolve(sessionId);
            if (touched != null) return new SelectedCredential(touched, sessionId);
        }
        return SelectedCredential.anonymous();
    }

    private static String sessionCookie(List<String> headers) {
        String found = null;
        int count = 0;
        for (String header : headers) {
            for (String part : header.split(";", -1)) {
                String pair = part.strip();
                int equals = pair.indexOf('=');
                String name = equals < 0 ? pair : pair.substring(0, equals).strip();
                if (SESSION_COOKIE.equals(name)) {
                    count++;
                    found = equals < 0 ? "" : pair.substring(equals + 1).strip();
                }
            }
        }
        if (count > 1) throw new SecurityFailure(SecurityFailure.Kind.AMBIGUOUS_CREDENTIALS);
        return found;
    }

    private static List<String> values(Enumeration<String> headers) {
        List<String> result = new ArrayList<>();
        if (headers != null) while (headers.hasMoreElements()) result.add(headers.nextElement());
        return result;
    }

    public static final class SelectedCredential {
        private final AuthenticatedPrincipal principal;
        private final String sessionId;

        private SelectedCredential(AuthenticatedPrincipal principal, String sessionId) {
            this.principal = principal;
            this.sessionId = sessionId;
        }

        private static SelectedCredential anonymous() { return new SelectedCredential(null, null); }
        public AuthenticatedPrincipal principal() { return principal; }
        public String sessionId() { return sessionId; }
        public boolean authenticated() { return principal != null; }

        @Override
        public String toString() { return "SelectedCredential[" + (principal == null ? "NONE" : principal.mechanism()) + "]"; }
    }
}
