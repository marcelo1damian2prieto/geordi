package io.geordi.bootstrap.security.oidc;

import io.geordi.bootstrap.security.PublicOrigin;
import io.geordi.bootstrap.security.SecurityFailure;
import io.geordi.bootstrap.security.metadata.TrustedIssuerMetadata;
import io.geordi.bootstrap.security.session.BoundedSessionStore;
import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.Objects;
import java.util.function.Supplier;

/** Fixed OIDC code+PKCE flow with one-use state and nonce-bound ID-token validation. */
public final class OidcAuthorizationFlow {
    private final BoundedSessionStore sessions;
    private final PublicOrigin publicOrigin;
    private final Supplier<TrustedIssuerMetadata> metadata;
    private final AuthorizationCodeTokenExchange tokenExchange;
    private final OidcIdTokenValidator idTokens;
    private final String clientId;

    public OidcAuthorizationFlow(BoundedSessionStore sessions, PublicOrigin publicOrigin,
            Supplier<TrustedIssuerMetadata> metadata, AuthorizationCodeTokenExchange tokenExchange,
            OidcIdTokenValidator idTokens, String clientId) {
        this.sessions = Objects.requireNonNull(sessions);
        this.publicOrigin = Objects.requireNonNull(publicOrigin);
        this.metadata = Objects.requireNonNull(metadata);
        this.tokenExchange = Objects.requireNonNull(tokenExchange);
        this.idTokens = Objects.requireNonNull(idTokens);
        this.clientId = Objects.requireNonNull(clientId);
    }

    public URI beginLogin() {
        return beginLogin(null);
    }

    public URI beginLogin(String priorSessionId) {
        var transaction = sessions.beginAuthorization(priorSessionId);
        try {
            String challenge = Base64.getUrlEncoder().withoutPadding().encodeToString(
                    MessageDigest.getInstance("SHA-256").digest(transaction.codeVerifier().getBytes(StandardCharsets.US_ASCII)));
            var endpoint = metadata.get().authorizationEndpoint();
            String query = "client_id=" + encode(clientId)
                    + "&response_type=code"
                    + "&response_mode=query"
                    + "&scope=" + encode("openid profile")
                    + "&redirect_uri=" + encode(publicOrigin.callback())
                    + "&state=" + encode(transaction.state())
                    + "&nonce=" + encode(transaction.nonce())
                    + "&code_challenge=" + encode(challenge)
                    + "&code_challenge_method=S256";
            String separator = endpoint.getRawQuery() == null ? "?" : "&";
            return URI.create(endpoint.toASCIIString() + separator + query);
        } catch (Exception failure) {
            sessions.discardAuthorization(transaction.state());
            throw new SecurityFailure(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
        }
    }

    public String completeCallback(String state, String code) {
        BoundedSessionStore.PendingAuthorization transaction = sessions.claimAuthorization(state);
        try {
            String idToken = tokenExchange.exchange(code, transaction.codeVerifier(), URI.create(publicOrigin.callback()));
            var principal = idTokens.validate(idToken, transaction.nonce());
            return sessions.completeAuthorization(state, principal);
        } catch (SecurityFailure failure) {
            sessions.discardAuthorization(state);
            throw failure;
        } catch (RuntimeException failure) {
            sessions.discardAuthorization(state);
            throw SecurityFailure.invalid();
        }
    }

    private static String encode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }
}
