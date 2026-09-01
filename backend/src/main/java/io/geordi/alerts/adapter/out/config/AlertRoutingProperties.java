package io.geordi.alerts.adapter.out.config;

import java.net.URI;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Pattern;
import org.springframework.boot.context.properties.ConfigurationProperties;

/** Deployment-managed M13 routing configuration; no runtime mutation is supported. */
@ConfigurationProperties(prefix = "geordi.alert-routing", ignoreUnknownFields = false)
public record AlertRoutingProperties(
        List<DestinationSettings> destinations,
        List<RouteSettings> routes,
        boolean allowInsecureLocalHttp) {

    public AlertRoutingProperties {
        destinations = destinations == null ? List.of() : List.copyOf(destinations);
        routes = routes == null ? List.of() : List.copyOf(routes);
    }

    public record DestinationSettings(String id, URI endpoint, String token, String tokenHeader) {

        private static final Pattern HEADER_NAME = Pattern.compile("[!#$%&'*+.^_`|~0-9A-Za-z-]+");
        private static final Pattern ID_PATTERN = Pattern.compile("[a-z0-9][a-z0-9-]{0,63}");
        private static final Set<String> RESERVED_HEADERS = Set.of(
                "connection", "content-length", "content-type", "expect", "host", "idempotency-key", "upgrade");

        public DestinationSettings {
            token = blankToNull(token);
            tokenHeader = blankToNull(tokenHeader);
            if (id == null || !ID_PATTERN.matcher(id).matches()) {
                throw new IllegalArgumentException(
                        "routing destination id must be a lowercase slug of at most 64 characters");
            }
            if (endpoint == null || endpoint.getUserInfo() != null || endpoint.getHost() == null
                    || endpoint.getQuery() != null || endpoint.getFragment() != null) {
                throw new IllegalArgumentException("routing destination endpoint is invalid");
            }
            boolean tokenPresent = token != null;
            boolean headerPresent = tokenHeader != null;
            if (tokenPresent != headerPresent) {
                throw new IllegalArgumentException("routing destination token and token header must be supplied together");
            }
            if (headerPresent && (!HEADER_NAME.matcher(tokenHeader).matches()
                    || RESERVED_HEADERS.contains(tokenHeader.toLowerCase(Locale.ROOT)))) {
                throw new IllegalArgumentException("routing destination token header is invalid");
            }
        }

        private static String blankToNull(String value) {
            return value == null || value.isBlank() ? null : value;
        }
    }

    public record RouteSettings(
            String id,
            String policyId,
            String serviceNamespace,
            String serviceName,
            String environment,
            String transitionType,
            String action,
            String destinationId) {
    }
}
