package io.geordi.traces.domain;

public record HttpMetadata(
        String requestMethod,
        String route,
        String path,
        Integer responseStatusCode,
        String serverAddress,
        Integer serverPort) {

    public HttpMetadata {
        requestMethod = normalize(requestMethod);
        route = normalize(route);
        path = normalize(path);
        serverAddress = normalize(serverAddress);
        if (responseStatusCode != null && (responseStatusCode < 100 || responseStatusCode > 599)) {
            throw new IllegalArgumentException("HTTP response status code is invalid");
        }
        if (serverPort != null && (serverPort < 1 || serverPort > 65_535)) {
            throw new IllegalArgumentException("server port is invalid");
        }
    }

    public boolean isEmpty() {
        return requestMethod == null && route == null && path == null && responseStatusCode == null
                && serverAddress == null && serverPort == null;
    }

    private static String normalize(String value) {
        return value == null || value.isBlank() ? null : value.trim();
    }
}
