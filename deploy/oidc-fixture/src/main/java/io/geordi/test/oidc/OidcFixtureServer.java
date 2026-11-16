package io.geordi.test.oidc;

import com.fasterxml.jackson.databind.JsonNode;
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
import java.security.Signature;
import java.security.interfaces.RSAPublicKey;
import java.security.KeyStore;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;

/** Ephemeral development-only OIDC issuer. Never linked into the Geordi backend artifact. */
public final class OidcFixtureServer {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final String CLIENT_ID = "geordi-browser";
    private static final String API_AUDIENCE = "geordi-api";
    private static final int MAX_FORM_BYTES = 8192;
    private static final Map<String, Set<String>> GRANTS = Map.of(
            "VIEWER", Set.of("VIEWER"),
            "OPERATOR", Set.of("OPERATOR"),
            "EVALUATOR", Set.of("EVALUATOR"),
            "REGRESSION", Set.of("VIEWER", "OPERATOR", "EVALUATOR"));

    private final String issuer;
    private final String clientSecret;
    private final String controlSecret;
    private final KeyPair signingKey;
    private final Map<String, Authorization> codes = new ConcurrentHashMap<>();
    private final HttpsServer issuerServer;
    private final HttpsServer browserServer;
    private final HttpsServer controlServer;

    private OidcFixtureServer() throws Exception {
        issuer = requiredEnvironment("GEORDI_OIDC_ISSUER");
        clientSecret = readSecret("/run/m19/client-secret");
        controlSecret = readSecret("/run/m19/control-secret");
        signingKey = KeyPairGenerator.getInstance("RSA").generateKeyPair();
        SSLContext tls = tlsContext();
        issuerServer = HttpsServer.create(new InetSocketAddress("0.0.0.0", 443), 32);
        issuerServer.setHttpsConfigurator(new HttpsConfigurator(tls));
        issuerServer.createContext("/.well-known/openid-configuration", this::discovery);
        issuerServer.createContext("/jwks", this::jwks);
        issuerServer.createContext("/authorize", this::authorize);
        issuerServer.createContext("/token", this::token);
        issuerServer.createContext("/health", exchange -> json(exchange, 200, Map.of("status", "UP")));

        browserServer = HttpsServer.create(new InetSocketAddress("0.0.0.0", 9445), 16);
        browserServer.setHttpsConfigurator(new HttpsConfigurator(tls));
        browserServer.createContext("/authorize", this::authorize);
        browserServer.createContext("/health", exchange -> json(exchange, 200, Map.of("status", "UP")));

        controlServer = HttpsServer.create(new InetSocketAddress("0.0.0.0", 8444), 8);
        controlServer.setHttpsConfigurator(new HttpsConfigurator(tls));
        controlServer.createContext("/__control/token", this::issueAccessToken);
        controlServer.createContext("/health", exchange -> json(exchange, 200, Map.of("status", "UP")));
        issuerServer.start();
        browserServer.start();
        controlServer.start();
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            issuerServer.stop(0);
            browserServer.stop(0);
            controlServer.stop(0);
        }));
    }

    public static void main(String[] arguments) throws Exception {
        if (arguments.length == 1 && "health".equals(arguments[0])) {
            try (var issuer = new java.net.Socket()) {
                issuer.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(), 443), 500);
            }
            try (var control = new java.net.Socket()) {
                control.connect(new InetSocketAddress(InetAddress.getLoopbackAddress(), 8444), 500);
            }
            return;
        }
        new OidcFixtureServer();
    }

    private void discovery(com.sun.net.httpserver.HttpExchange exchange) throws IOException {
        if (!"GET".equals(exchange.getRequestMethod())) { methodNotAllowed(exchange); return; }
        json(exchange, 200, Map.of("issuer", issuer, "authorization_endpoint", issuer + ":9445/authorize",
                "token_endpoint", issuer + "/token", "jwks_uri", issuer + "/jwks",
                "response_types_supported", new String[] {"code"},
                "code_challenge_methods_supported", new String[] {"S256"},
                "token_endpoint_auth_methods_supported", new String[] {"client_secret_basic"}));
    }

    private void jwks(com.sun.net.httpserver.HttpExchange exchange) throws IOException {
        if (!"GET".equals(exchange.getRequestMethod())) { methodNotAllowed(exchange); return; }
        RSAPublicKey key = (RSAPublicKey) signingKey.getPublic();
        json(exchange, 200, Map.of("keys", new Object[] {Map.of("kid", "m19-fixture-key", "kty", "RSA",
                "use", "sig", "alg", "RS256", "n", base64(unsigned(key.getModulus().toByteArray())),
                "e", base64(unsigned(key.getPublicExponent().toByteArray())))}));
    }

    private void authorize(com.sun.net.httpserver.HttpExchange exchange) throws IOException {
        if (!"GET".equals(exchange.getRequestMethod())) { methodNotAllowed(exchange); return; }
        Map<String, String> query = parse(exchange.getRequestURI().getRawQuery());
        String redirect = query.get("redirect_uri");
        String state = query.get("state");
        String nonce = query.get("nonce");
        String challenge = query.get("code_challenge");
        if (!"code".equals(query.get("response_type")) || !"S256".equals(query.get("code_challenge_method"))
                || !CLIENT_ID.equals(query.get("client_id")) || !"query".equals(query.get("response_mode"))
                || !"openid profile".equals(query.get("scope"))
                || !"https://geordi.localhost:8443/login/oauth2/code/geordi".equals(redirect)
                || !validOpaque(state) || !validOpaque(nonce) || !validChallenge(challenge)) {
            json(exchange, 400, Map.of("error", "invalid_request"));
            return;
        }
        String code = UUID.randomUUID().toString();
        codes.put(code, new Authorization(redirect, nonce, challenge));
        exchange.getResponseHeaders().set("Location", redirect + "?code=" + code + "&state=" + encode(state));
        exchange.getResponseHeaders().set("Cache-Control", "no-store");
        exchange.sendResponseHeaders(302, -1);
        exchange.close();
    }

    private void token(com.sun.net.httpserver.HttpExchange exchange) throws IOException {
        if (!"POST".equals(exchange.getRequestMethod())) { methodNotAllowed(exchange); return; }
        String encodedClient = java.net.URLEncoder.encode(CLIENT_ID, StandardCharsets.UTF_8);
        String encodedSecret = java.net.URLEncoder.encode(clientSecret, StandardCharsets.UTF_8);
        String expected = "Basic " + Base64.getEncoder().encodeToString((encodedClient + ":" + encodedSecret)
                .getBytes(StandardCharsets.UTF_8));
        if (!constantTimeEquals(expected, exchange.getRequestHeaders().getFirst("Authorization"))) {
            json(exchange, 401, Map.of("error", "invalid_client"));
            return;
        }
        byte[] body = exchange.getRequestBody().readNBytes(MAX_FORM_BYTES + 1);
        if (body.length > MAX_FORM_BYTES) { json(exchange, 400, Map.of("error", "invalid_request")); return; }
        Map<String, String> form = parse(new String(body, StandardCharsets.UTF_8));
        Authorization authorization = codes.remove(form.get("code"));
        if (authorization == null || !"authorization_code".equals(form.get("grant_type"))
                || !authorization.redirectUri.equals(form.get("redirect_uri"))
                || !authorization.challenge.equals(challenge(form.get("code_verifier")))) {
            json(exchange, 400, Map.of("error", "invalid_grant"));
            return;
        }
        String idToken = signedToken("JWT", Map.of("iss", issuer, "sub", "m19-operator", "name", "M19 Operator",
                "aud", CLIENT_ID, "iat", Instant.now().getEpochSecond(),
                "exp", Instant.now().plusSeconds(300).getEpochSecond(), "nonce", authorization.nonce,
                "geordi_permissions", new String[] {"OPERATOR"}));
        json(exchange, 200, Map.of("id_token", idToken, "token_type", "Bearer", "expires_in", 300));
    }

    private void issueAccessToken(com.sun.net.httpserver.HttpExchange exchange) throws IOException {
        if (!"POST".equals(exchange.getRequestMethod())) { methodNotAllowed(exchange); return; }
        String supplied = exchange.getRequestHeaders().getFirst("X-Geordi-Fixture-Control");
        if (!constantTimeEquals(controlSecret, supplied)) { json(exchange, 401, Map.of("error", "unauthorized")); return; }
        byte[] body = exchange.getRequestBody().readNBytes(1025);
        if (body.length > 1024) { json(exchange, 400, Map.of("error", "invalid_request")); return; }
        JsonNode request = JSON.readTree(body);
        String role = request == null || !request.path("identity").isTextual()
                ? "" : request.path("identity").textValue();
        String subject = request != null && request.path("alternateOperator").asBoolean(false)
                && "OPERATOR".equals(role) ? "m19-operator-alt" : "m19-" + role.toLowerCase();
        boolean wrongAudience = request != null && request.path("wrongAudience").asBoolean(false);
        boolean idToken = request != null && request.path("idToken").asBoolean(false);
        Set<String> permissions = GRANTS.get(role);
        if (permissions == null) { json(exchange, 400, Map.of("error", "invalid_identity")); return; }
        Instant issued = Instant.now();
        String tokenType = idToken ? "JWT" : "at+jwt";
        String audience = wrongAudience ? "geordi-wrong-audience" : (idToken ? CLIENT_ID : API_AUDIENCE);
        String token = signedToken(tokenType, Map.of("iss", issuer, "sub", subject,
                "name", "M19 " + role, "aud", audience, "client_id", "geordi-regression-client",
                "jti", UUID.randomUUID().toString(), "iat", issued.getEpochSecond(),
                "exp", issued.plusSeconds(240).getEpochSecond(), "geordi_permissions", permissions));
        json(exchange, 200, Map.of("access_token", token, "token_type", "Bearer", "expires_in", 240));
    }

    private SSLContext tlsContext() throws Exception {
        char[] password = readSecret("/run/m19/auth.password").toCharArray();
        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        try (var input = Files.newInputStream(Path.of("/run/m19/auth.p12"))) { keyStore.load(input, password); }
        KeyManagerFactory managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        managers.init(keyStore, password);
        SSLContext context = SSLContext.getInstance("TLS");
        context.init(managers.getKeyManagers(), null, null);
        java.util.Arrays.fill(password, '\0');
        return context;
    }

    private String signedToken(String type, Map<String, Object> claims) {
        try {
            String header = base64(JSON.writeValueAsBytes(Map.of("alg", "RS256", "typ", type,
                    "kid", "m19-fixture-key")));
            String payload = base64(JSON.writeValueAsBytes(claims));
            String input = header + "." + payload;
            Signature signature = Signature.getInstance("SHA256withRSA");
            signature.initSign(signingKey.getPrivate());
            signature.update(input.getBytes(StandardCharsets.US_ASCII));
            return input + "." + base64(signature.sign());
        } catch (Exception failure) {
            throw new IllegalStateException("M19 fixture token signing failed");
        }
    }

    private static void json(com.sun.net.httpserver.HttpExchange exchange, int status, Object value) throws IOException {
        byte[] bytes = JSON.writeValueAsBytes(value);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.getResponseHeaders().set("Cache-Control", "no-store");
        exchange.sendResponseHeaders(status, bytes.length);
        try (var output = exchange.getResponseBody()) { output.write(bytes); }
    }

    private static Map<String, String> parse(String encoded) {
        Map<String, String> result = new LinkedHashMap<>();
        if (encoded == null || encoded.length() > MAX_FORM_BYTES) return result;
        for (String pair : encoded.split("&")) {
            String[] parts = pair.split("=", 2);
            if (parts.length == 2) result.put(URLDecoder.decode(parts[0], StandardCharsets.UTF_8),
                    URLDecoder.decode(parts[1], StandardCharsets.UTF_8));
        }
        return result;
    }

    private static String challenge(String verifier) {
        if (verifier == null || verifier.length() < 43 || verifier.length() > 128
                || !verifier.matches("[A-Za-z0-9._~-]+")) return "";
        try {
            return base64(java.security.MessageDigest.getInstance("SHA-256")
                    .digest(verifier.getBytes(StandardCharsets.US_ASCII)));
        } catch (Exception failure) { throw new IllegalStateException("M19 fixture PKCE check failed"); }
    }

    private static boolean validOpaque(String value) {
        return value != null && value.length() >= 32 && value.length() <= 128
                && value.matches("[A-Za-z0-9_-]+");
    }

    private static boolean validChallenge(String value) {
        return value != null && value.matches("[A-Za-z0-9_-]{43}");
    }

    private static String requiredEnvironment(String name) {
        String value = System.getenv(name);
        if (value == null || !value.equals("https://auth.localhost")) {
            throw new IllegalStateException("M19 fixture issuer configuration is invalid");
        }
        return value;
    }

    private static String readSecret(String path) throws IOException {
        byte[] bytes = Files.readAllBytes(Path.of(path));
        try {
            if (bytes.length == 0 || bytes.length > 4096) throw new IllegalArgumentException("fixture secret is invalid");
            return new String(bytes, StandardCharsets.UTF_8).trim();
        } finally { java.util.Arrays.fill(bytes, (byte) 0); }
    }

    private static boolean constantTimeEquals(String expected, String actual) {
        if (actual == null) return false;
        return java.security.MessageDigest.isEqual(expected.getBytes(StandardCharsets.UTF_8),
                actual.getBytes(StandardCharsets.UTF_8));
    }

    private static byte[] unsigned(byte[] value) {
        return value.length > 1 && value[0] == 0 ? java.util.Arrays.copyOfRange(value, 1, value.length) : value;
    }

    private static String base64(byte[] value) { return Base64.getUrlEncoder().withoutPadding().encodeToString(value); }
    private static String encode(String value) { return java.net.URLEncoder.encode(value, StandardCharsets.UTF_8); }
    private static void methodNotAllowed(com.sun.net.httpserver.HttpExchange exchange) throws IOException {
        exchange.getResponseHeaders().set("Allow", "GET, POST");
        exchange.sendResponseHeaders(405, -1);
        exchange.close();
    }

    private record Authorization(String redirectUri, String nonce, String challenge) { }
}
