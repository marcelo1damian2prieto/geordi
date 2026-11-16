package io.geordi.bootstrap.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.security.jwt.AccessTokenProfile;
import io.geordi.bootstrap.security.jwt.JwksDocumentFetcher;
import io.geordi.bootstrap.security.jwt.TrustedJwksKeyCache;
import io.geordi.bootstrap.security.metadata.BoundedHttpsJsonClient;
import io.geordi.bootstrap.security.metadata.OidcMetadataClient;
import io.geordi.bootstrap.security.metadata.TrustedIssuerMetadata;
import io.geordi.bootstrap.security.oidc.OidcAuthorizationCodeTokenClient;
import io.geordi.bootstrap.security.oidc.OidcAuthorizationFlow;
import io.geordi.bootstrap.security.oidc.OidcIdTokenValidator;
import io.geordi.bootstrap.security.session.BoundedSessionStore;
import io.geordi.core.application.security.SecurityObservation;
import java.net.URI;
import java.security.SecureRandom;
import java.time.Clock;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.core.Ordered;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.annotation.Scheduled;

/** Required M19 authentication composition. Missing or untrusted OIDC configuration fails startup. */
@Configuration(proxyBeanMethods = false)
@EnableConfigurationProperties(SecurityProperties.class)
@EnableScheduling
public class SecurityComposition {

    @Bean
    Clock securityClock() {
        return Clock.systemUTC();
    }

    @Bean
    SecureRandom securityRandom() {
        return new SecureRandom();
    }

    @Bean
    BoundedHttpsJsonClient oidcHttpsClient() {
        return new BoundedHttpsJsonClient();
    }

    @Bean
    TrustedIssuerMetadata trustedIssuerMetadata(SecurityProperties properties, BoundedHttpsJsonClient transport) {
        return new OidcMetadataClient(properties.issuer(), transport).discover();
    }

    @Bean
    TrustedJwksKeyCache trustedJwksKeyCache(TrustedIssuerMetadata metadata,
            BoundedHttpsJsonClient transport, Clock securityClock) {
        URI jwks = metadata.jwksUri();
        TrustedJwksKeyCache cache = new TrustedJwksKeyCache(
                (JwksDocumentFetcher) () -> transport.get(jwks, 256 * 1024).toString(), securityClock);
        cache.initialize();
        return cache;
    }

    @Bean
    ExternalGrantMapper externalGrantMapper(SecurityProperties properties) {
        return new ExternalGrantMapper(properties.permissions());
    }

    @Bean
    AccessTokenProfile accessTokenProfile(SecurityProperties properties, ExternalGrantMapper grants,
            TrustedJwksKeyCache keys, Clock securityClock) {
        return new AccessTokenProfile(properties.issuer(), properties.apiAudience(), properties.grantClaim(),
                grants, keys, securityClock);
    }

    @Bean
    BoundedSessionStore boundedSessionStore(Clock securityClock, SecureRandom securityRandom) {
        return new BoundedSessionStore(securityClock, securityRandom);
    }

    @Bean
    OidcIdTokenValidator oidcIdTokenValidator(SecurityProperties properties, ExternalGrantMapper grants,
            TrustedJwksKeyCache keys, Clock securityClock) {
        return new OidcIdTokenValidator(properties.issuer(), properties.browserClientId(), properties.grantClaim(),
                grants, keys, securityClock);
    }

    @Bean
    OidcAuthorizationCodeTokenClient oidcTokenClient(BoundedHttpsJsonClient transport,
            TrustedIssuerMetadata metadata, SecurityProperties properties) {
        return new OidcAuthorizationCodeTokenClient(transport, metadata, properties);
    }

    @Bean
    OidcAuthorizationFlow oidcAuthorizationFlow(BoundedSessionStore sessions, SecurityProperties properties,
            TrustedIssuerMetadata metadata, OidcAuthorizationCodeTokenClient tokens,
            OidcIdTokenValidator idTokens) {
        return new OidcAuthorizationFlow(sessions, new PublicOrigin(properties.publicBaseUrl()),
                () -> metadata, tokens, idTokens, properties.browserClientId());
    }

    @Bean
    CredentialSelection credentialSelection(BoundedSessionStore sessions, AccessTokenProfile tokens) {
        return new CredentialSelection(sessions, tokens);
    }

    @Bean
    RoutePermissionPolicy routePermissionPolicy() {
        return new RoutePermissionPolicy();
    }

    @Bean
    PublicOrigin publicOrigin(SecurityProperties properties) {
        return new PublicOrigin(properties.publicBaseUrl());
    }

    @Bean
    GeordiSecurityFilter geordiSecurityFilter(RoutePermissionPolicy routes, CredentialSelection credentials,
            BoundedSessionStore sessions, OidcAuthorizationFlow oidc, PublicOrigin origin,
            SecurityObservation observations, ObjectMapper json) {
        return new GeordiSecurityFilter(routes, credentials, sessions, oidc, origin, observations, json);
    }

    @Bean
    FilterRegistrationBean<GeordiSecurityFilter> geordiSecurityFilterRegistration(GeordiSecurityFilter filter) {
        FilterRegistrationBean<GeordiSecurityFilter> registration = new FilterRegistrationBean<>(filter);
        registration.setName("geordiSecurityFilter");
        registration.setOrder(Ordered.HIGHEST_PRECEDENCE);
        registration.setDispatcherTypes(jakarta.servlet.DispatcherType.REQUEST, jakarta.servlet.DispatcherType.ERROR);
        registration.addUrlPatterns("/*");
        return registration;
    }

    @Bean
    SessionCleanup sessionCleanup(BoundedSessionStore sessions) {
        return new SessionCleanup(sessions);
    }

    /** Spring schedules cleanup; the session store retains its atomic bounded expiry operation. */
    public static final class SessionCleanup {
        private final BoundedSessionStore sessions;

        private SessionCleanup(BoundedSessionStore sessions) {
            this.sessions = sessions;
        }

        @Scheduled(fixedDelay = 60_000)
        public void cleanExpired() {
            sessions.cleanupExpired();
        }
    }
}
