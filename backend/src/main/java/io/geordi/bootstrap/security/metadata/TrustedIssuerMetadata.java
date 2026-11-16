package io.geordi.bootstrap.security.metadata;

import java.net.URI;

/** Minimal validated endpoints used by the token and browser protocol adapters. */
public record TrustedIssuerMetadata(String issuer, URI authorizationEndpoint, URI tokenEndpoint, URI jwksUri) { }
