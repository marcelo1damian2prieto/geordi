package io.geordi.bootstrap.security.metadata;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.bootstrap.security.SecurityFailure;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.nio.file.Files;
import java.nio.file.Path;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.net.URLEncoder;
import java.util.Map;
import java.util.List;
import java.util.Base64;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Flow;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** Certificate-validating HTTPS JSON transport with redirect, deadline, and streaming size bounds. */
public final class BoundedHttpsJsonClient {
    private static final System.Logger LOGGER = System.getLogger(BoundedHttpsJsonClient.class.getName());
    private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(2);
    private static final Duration OPERATION_TIMEOUT = Duration.ofSeconds(5);
    private static final ObjectMapper JSON = new ObjectMapper(JsonFactory.builder()
            .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION).build());

    private final HttpClient client;
    private final Duration operationTimeout;

    public BoundedHttpsJsonClient() {
        this(OPERATION_TIMEOUT);
    }

    BoundedHttpsJsonClient(Duration operationTimeout) {
        this(operationTimeout, testTrustContext());
    }

    BoundedHttpsJsonClient(Duration operationTimeout, Path trustStoreFile, Path passwordFile) {
        this(operationTimeout, loadTrustContext(trustStoreFile, passwordFile));
    }

    private BoundedHttpsJsonClient(Duration operationTimeout, javax.net.ssl.SSLContext context) {
        this.operationTimeout = operationTimeout;
        client = HttpClient.newBuilder().connectTimeout(CONNECT_TIMEOUT)
                .sslContext(context)
                .followRedirects(HttpClient.Redirect.NEVER).build();
    }

    private static javax.net.ssl.SSLContext testTrustContext() {
        String passwordFile = System.getenv("GEORDI_TEST_TRUSTSTORE_PASSWORD_FILE");
        if (passwordFile == null || passwordFile.isBlank()) return defaultTrustContext();
        String storeFile = System.getenv("GEORDI_TEST_TRUSTSTORE_FILE");
        if (storeFile == null || storeFile.isBlank()) throw new IllegalStateException("Invalid test trust configuration");
        return loadTrustContext(Path.of(storeFile), Path.of(passwordFile));
    }

    static javax.net.ssl.SSLContext loadTrustContext(Path storeFile, Path passwordFile) {
        char[] password = null;
        try {
            password = Files.readString(passwordFile, StandardCharsets.UTF_8).trim().toCharArray();
            if (password.length == 0 || password.length > 256) throw new IllegalStateException("Invalid test trust configuration");
            java.security.KeyStore trustStore = java.security.KeyStore.getInstance("PKCS12");
            try (var input = Files.newInputStream(storeFile)) {
                trustStore.load(input, password);
            }
            javax.net.ssl.TrustManagerFactory managers = javax.net.ssl.TrustManagerFactory
                    .getInstance(javax.net.ssl.TrustManagerFactory.getDefaultAlgorithm());
            managers.init(trustStore);
            javax.net.ssl.SSLContext context = javax.net.ssl.SSLContext.getInstance("TLS");
            context.init(null, managers.getTrustManagers(), null);
            return context;
        } catch (Exception failure) {
            logFailure("Configured TLS trust store initialization", failure);
            throw new IllegalStateException("Could not initialize the configured test trust store");
        } finally {
            if (password != null) java.util.Arrays.fill(password, '\0');
        }
    }

    private static javax.net.ssl.SSLContext defaultTrustContext() {
        try {
            return javax.net.ssl.SSLContext.getDefault();
        } catch (java.security.NoSuchAlgorithmException failure) {
            logFailure("Default TLS context initialization", failure);
            throw new IllegalStateException("Default TLS context is unavailable");
        }
    }

    public JsonNode get(URI uri, int maximumBytes) {
        try {
            return execute(HttpRequest.newBuilder(checked(uri, maximumBytes)).timeout(operationTimeout)
                    .header("Accept", "application/json").GET().build(), maximumBytes);
        } catch (SecurityFailure failure) {
            throw failure;
        } catch (Exception failure) {
            logFailure("HTTPS GET", failure);
            throw unavailable();
        }
    }

    public JsonNode postForm(URI uri, int maximumBytes, Map<String, String> form,
            String clientId, String clientSecret) {
        try {
            String body = form.entrySet().stream().map(entry -> encode(entry.getKey()) + "=" + encode(entry.getValue()))
                    .collect(java.util.stream.Collectors.joining("&"));
            String credentials = encode(clientId) + ":" + encode(clientSecret);
            String basic = Base64.getEncoder().encodeToString(credentials.getBytes(StandardCharsets.UTF_8));
            HttpRequest request = HttpRequest.newBuilder(checked(uri, maximumBytes)).timeout(operationTimeout)
                    .header("Accept", "application/json")
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .header("Authorization", "Basic " + basic)
                    .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8)).build();
            return execute(request, maximumBytes);
        } catch (SecurityFailure failure) {
            throw failure;
        } catch (Exception failure) {
            logFailure("HTTPS form POST", failure);
            throw unavailable();
        }
    }

    private JsonNode execute(HttpRequest request, int maximumBytes) throws Exception {
        CompletableFuture<HttpResponse<byte[]>> exchange = client.sendAsync(request,
                information -> new BoundedBodySubscriber(maximumBytes));
        HttpResponse<byte[]> response;
        try {
            response = exchange.get(operationTimeout.toMillis(), TimeUnit.MILLISECONDS);
        } catch (TimeoutException timeout) {
            exchange.cancel(true);
            throw timeout;
        } catch (Exception failure) {
            exchange.cancel(true);
            throw failure;
        }
        if (response.statusCode() != 200) throw unavailable();
        String contentType = response.headers().firstValue("content-type").orElse("");
        if (!contentType.toLowerCase(java.util.Locale.ROOT).startsWith("application/json")) throw unavailable();
        return JSON.readTree(response.body());
    }

    private static URI checked(URI uri, int maximumBytes) {
        if (uri == null || !"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null
                || uri.getUserInfo() != null || uri.getFragment() != null || maximumBytes < 1) throw unavailable();
        return uri;
    }

    private static String encode(String value) {
        if (value == null) throw unavailable();
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    private static SecurityFailure unavailable() {
        return new SecurityFailure(SecurityFailure.Kind.DEPENDENCY_UNAVAILABLE);
    }

    /**
     * Logs only exception type names. Exception messages and stack traces are intentionally omitted because
     * transport failures may contain endpoint details or other data that should not cross the security boundary.
     */
    private static void logFailure(String operation, Throwable failure) {
        StringBuilder types = new StringBuilder();
        Throwable current = failure;
        int depth = 0;
        while (current != null && depth < 5) {
            if (depth > 0) types.append(" -> ");
            types.append(current.getClass().getName());
            current = current.getCause();
            depth++;
        }
        LOGGER.log(System.Logger.Level.WARNING, "{0} failed; exception chain: {1}", operation, types);
    }

    private static final class BoundedBodySubscriber implements HttpResponse.BodySubscriber<byte[]> {
        private final int maximumBytes;
        private final ByteArrayOutputStream output = new ByteArrayOutputStream();
        private final CompletableFuture<byte[]> body = new CompletableFuture<>();
        private Flow.Subscription subscription;

        private BoundedBodySubscriber(int maximumBytes) {
            this.maximumBytes = maximumBytes;
        }

        @Override
        public java.util.concurrent.CompletionStage<byte[]> getBody() {
            return body;
        }

        @Override
        public void onSubscribe(Flow.Subscription received) {
            subscription = received;
            received.request(1);
        }

        @Override
        public void onNext(List<ByteBuffer> buffers) {
            try {
                for (ByteBuffer buffer : buffers) {
                    int length = buffer.remaining();
                    if (length > maximumBytes - output.size()) {
                        subscription.cancel();
                        body.completeExceptionally(new IllegalArgumentException("bounded response exceeded"));
                        return;
                    }
                    byte[] chunk = new byte[length];
                    buffer.get(chunk);
                    output.write(chunk);
                }
                subscription.request(1);
            } catch (java.io.IOException | RuntimeException failure) {
                subscription.cancel();
                body.completeExceptionally(failure);
            }
        }

        @Override
        public void onError(Throwable failure) {
            body.completeExceptionally(failure);
        }

        @Override
        public void onComplete() {
            body.complete(output.toByteArray());
        }
    }
}
