package io.geordi.bootstrap.security.jwt;

import java.security.PublicKey;

/** Supplies keys only from the configured, certificate-validated issuer metadata. */
@FunctionalInterface
public interface TrustedAccessTokenKeyResolver {
    PublicKey resolve(String keyId);
}
