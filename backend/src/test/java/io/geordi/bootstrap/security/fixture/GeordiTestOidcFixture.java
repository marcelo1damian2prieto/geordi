package io.geordi.bootstrap.security.fixture;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpsConfigurator;
import com.sun.net.httpserver.HttpsServer;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.Signature;
import java.security.interfaces.RSAPublicKey;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;

/** Loopback-only HTTPS issuer reused by Spring integration tests. */
public final class GeordiTestOidcFixture {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String CLIENT_ID = "geordi-browser";
    private static final String CLIENT_SECRET = "m19-test-client-secret";
    private static final String GRANT_CLAIM = "geordi_permissions";
    private static GeordiTestOidcFixture instance;

    private final HttpsServer server;
    private final KeyPair signingKey;
    private final String issuer;
    private final Path secretFile;
    private final Map<String, Authorization> codes = new ConcurrentHashMap<>();

    private GeordiTestOidcFixture() throws Exception {
        Path directory = Files.createTempDirectory("geordi-m19-oidc-");
        directory.toFile().deleteOnExit();
        String storePassword = UUID.randomUUID().toString();
        Path keyStoreFile = directory.resolve("issuer.p12");
        Path trustStoreFile = directory.resolve("trust.p12");
        runKeytool(directory, storePassword, "-genkeypair", "-alias", "issuer", "-keyalg", "RSA", "-keysize", "2048",
                "-validity", "2", "-storetype", "PKCS12", "-keystore", keyStoreFile.toString(),
                "-storepass:env", "GEORDI_TEST_STORE_PASSWORD", "-keypass:env", "GEORDI_TEST_STORE_PASSWORD",
                "-dname", "CN=localhost", "-ext", "SAN=dns:localhost");
        Path certificate = directory.resolve("issuer.pem");
        runKeytool(directory, storePassword, "-exportcert", "-rfc", "-alias", "issuer", "-keystore",
                keyStoreFile.toString(), "-storetype", "PKCS12", "-storepass:env", "GEORDI_TEST_STORE_PASSWORD",
                "-file", certificate.toString());
        runKeytool(directory, storePassword, "-importcert", "-noprompt", "-alias", "geordi-test-issuer",
                "-file", certificate.toString(), "-keystore", trustStoreFile.toString(), "-storetype", "PKCS12",
                "-storepass:env", "GEORDI_TEST_STORE_PASSWORD");
        keyStoreFile.toFile().deleteOnExit();
        trustStoreFile.toFile().deleteOnExit();
        certificate.toFile().deleteOnExit();
        System.setProperty("javax.net.ssl.trustStore", trustStoreFile.toString());
        System.setProperty("javax.net.ssl.trustStorePassword", storePassword);

        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        try (var input = Files.newInputStream(keyStoreFile)) {
            keyStore.load(input, storePassword.toCharArray());
        }
        KeyManagerFactory keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        keyManagers.init(keyStore, storePassword.toCharArray());
        TrustManagerFactory trustManagers = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        trustManagers.init(keyStore);
        SSLContext ssl = SSLContext.getInstance("TLS");
        ssl.init(keyManagers.getKeyManagers(), trustManagers.getTrustManagers(), null);
        server = HttpsServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 32);
        server.setHttpsConfigurator(new HttpsConfigurator(ssl));
        issuer = "https://localhost:" + server.getAddress().getPort();
        secretFile = directory.resolve("client-secret");
        Files.writeString(secretFile, CLIENT_SECRET, StandardCharsets.US_ASCII);
        secretFile.toFile().deleteOnExit();
        signingKey = KeyPairGenerator.getInstance("RSA").generateKeyPair();
        server.createContext("/.well-known/openid-configuration", exchange -> json(exchange, 200, Map.of(
                "issuer", issuer, "authorization_endpoint", issuer + "/authorize", "token_endpoint", issuer + "/token",
                "jwks_uri", issuer + "/jwks", "response_types_supported", new String[] {"code"},
                "code_challenge_methods_supported", new String[] {"S256"},
                "token_endpoint_auth_methods_supported", new String[] {"client_secret_basic"})));
        server.createContext("/jwks", exchange -> json(exchange, 200, Map.of("keys", new Object[] {publicJwk()})));
        server.createContext("/authorize", exchange -> authorize(exchange));
        server.createContext("/token", exchange -> token(exchange));
        server.createContext("/health", exchange -> json(exchange, 200, Map.of("status", "UP")));
        server.createContext("/slow-body", exchange -> {
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, 0);
            try (var output = exchange.getResponseBody()) {
                output.write('{');
                output.flush();
                try {
                    Thread.sleep(2_000);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
                output.write('}');
            }
        });
        server.start();
    }

    public static synchronized GeordiTestOidcFixture instance() {
        if (instance == null) {
            try {
                instance = new GeordiTestOidcFixture();
            } catch (Exception failure) {
                throw new IllegalStateException("M19 HTTPS issuer fixture could not start", failure);
            }
        }
        return instance;
    }

    public String issuer() { return issuer; }
    public Path secretFile() { return secretFile; }
    public String accessToken() {
        return signedToken("at+jwt", Map.of("iss", issuer, "sub", "test-operator", "name", "Test Operator",
                "aud", "geordi-api", "client_id", "geordi-test-client", "jti", UUID.randomUUID().toString(),
                "iat", Instant.now().getEpochSecond(), "exp", Instant.now().plusSeconds(300).getEpochSecond(),
                GRANT_CLAIM, new String[] {"OPERATOR", "EVALUATOR"}));
    }

    public int port() { return server.getAddress().getPort(); }

    private void authorize(com.sun.net.httpserver.HttpExchange exchange) throws IOException {
        Map<String, String> query = parse(new String(exchange.getRequestURI().getRawQuery()
                .getBytes(StandardCharsets.UTF_8), StandardCharsets.UTF_8));
        if (!"code".equals(query.get("response_type")) || !"S256".equals(query.get("code_challenge_method"))
                || !CLIENT_ID.equals(query.get("client_id")) || !validRedirect(query.get("redirect_uri"))) {
            json(exchange, 400, Map.of("error", "invalid_request"));
            return;
        }
        String code = UUID.randomUUID().toString();
        codes.put(code, new Authorization(query.get("redirect_uri"), query.get("nonce"), query.get("code_challenge")));
        exchange.getResponseHeaders().set("Location", query.get("redirect_uri") + "?code=" + code
                + "&state=" + query.get("state"));
        exchange.sendResponseHeaders(302, -1);
        exchange.close();
    }

    private void token(com.sun.net.httpserver.HttpExchange exchange) throws IOException {
        String expected = "Basic " + Base64.getEncoder().encodeToString((CLIENT_ID + ":" + CLIENT_SECRET)
                .getBytes(StandardCharsets.UTF_8));
        if (!expected.equals(exchange.getRequestHeaders().getFirst("Authorization"))) {
            json(exchange, 401, Map.of("error", "invalid_client"));
            return;
        }
        String body = new String(exchange.getRequestBody().readNBytes(8193), StandardCharsets.UTF_8);
        if (body.length() > 8192) {
            json(exchange, 400, Map.of("error", "invalid_request"));
            return;
        }
        Map<String, String> form = parse(body);
        Authorization authorization = codes.remove(form.get("code"));
        if (authorization == null || !authorization.redirectUri.equals(form.get("redirect_uri"))
                || !authorization.challenge.equals(challenge(form.get("code_verifier")))) {
            json(exchange, 400, Map.of("error", "invalid_grant"));
            return;
        }
        String idToken = signedToken("JWT", Map.of("iss", issuer, "sub", "test-operator", "name", "Test Operator",
                "aud", CLIENT_ID, "iat", Instant.now().getEpochSecond(),
                "exp", Instant.now().plusSeconds(300).getEpochSecond(), "nonce", authorization.nonce,
                GRANT_CLAIM, new String[] {"OPERATOR"}));
        json(exchange, 200, Map.of("id_token", idToken, "token_type", "Bearer", "expires_in", 300));
    }

    private boolean validRedirect(String value) {
        return value != null && value.equals("https://geordi.localhost/login/oauth2/code/geordi");
    }

    private Map<String, Object> publicJwk() {
        RSAPublicKey key = (RSAPublicKey) signingKey.getPublic();
        return Map.of("kid", "test-key", "kty", "RSA", "use", "sig", "alg", "RS256",
                "n", base64(unsigned(key.getModulus().toByteArray())),
                "e", base64(unsigned(key.getPublicExponent().toByteArray())));
    }

    private String signedToken(String type, Map<String, Object> claims) {
        try {
            String header = base64(JSON.writeValueAsBytes(Map.of("alg", "RS256", "typ", type, "kid", "test-key")));
            String payload = base64(JSON.writeValueAsBytes(claims));
            String input = header + "." + payload;
            Signature signature = Signature.getInstance("SHA256withRSA");
            signature.initSign(signingKey.getPrivate());
            signature.update(input.getBytes(StandardCharsets.US_ASCII));
            return input + "." + base64(signature.sign());
        } catch (Exception failure) {
            throw new IllegalStateException("M19 test token could not be signed");
        }
    }

    private static String challenge(String verifier) {
        if (verifier == null) return "";
        try {
            return base64(java.security.MessageDigest.getInstance("SHA-256")
                    .digest(verifier.getBytes(StandardCharsets.US_ASCII)));
        } catch (Exception failure) {
            throw new IllegalStateException("M19 test verifier could not be checked");
        }
    }

    private static Map<String, String> parse(String encoded) {
        Map<String, String> values = new LinkedHashMap<>();
        for (String pair : encoded.split("&")) {
            String[] parts = pair.split("=", 2);
            if (parts.length == 2) values.put(URLDecoder.decode(parts[0], StandardCharsets.UTF_8),
                    URLDecoder.decode(parts[1], StandardCharsets.UTF_8));
        }
        return values;
    }

    private static void json(com.sun.net.httpserver.HttpExchange exchange, int status, Object value) throws IOException {
        byte[] bytes = JSON.writeValueAsBytes(value);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.getResponseHeaders().set("Cache-Control", "no-store");
        exchange.sendResponseHeaders(status, bytes.length);
        try (var output = exchange.getResponseBody()) { output.write(bytes); }
    }

    private static void runKeytool(Path directory, String password, String... arguments) throws Exception {
        String executable = Path.of(System.getProperty("java.home"), "bin",
                System.getProperty("os.name").toLowerCase().contains("win") ? "keytool.exe" : "keytool").toString();
        var command = new java.util.ArrayList<String>();
        command.add(executable);
        command.addAll(java.util.List.of(arguments));
        ProcessBuilder builder = new ProcessBuilder(command).directory(directory.toFile()).redirectErrorStream(true);
        builder.environment().put("GEORDI_TEST_STORE_PASSWORD", password);
        Process process = builder.start();
        byte[] output = process.getInputStream().readNBytes(4097);
        if (!process.waitFor(30, java.util.concurrent.TimeUnit.SECONDS) || process.exitValue() != 0) {
            process.destroyForcibly();
            throw new IOException("M19 test TLS material generation failed: "
                    + new String(output, StandardCharsets.UTF_8).replaceAll("[\\r\\n]+", " "));
        }
    }

    private static String base64(byte[] bytes) { return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes); }
    private static byte[] unsigned(byte[] bytes) {
        return bytes.length > 1 && bytes[0] == 0 ? java.util.Arrays.copyOfRange(bytes, 1, bytes.length) : bytes;
    }

    private record Authorization(String redirectUri, String nonce, String challenge) { }
}
