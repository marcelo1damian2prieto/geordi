package io.geordi.bootstrap.security.jwt;

/** Implementations use trusted HTTPS, forbid redirects, and enforce byte/time limits while reading. */
@FunctionalInterface
public interface JwksDocumentFetcher {
    String fetch();
}
