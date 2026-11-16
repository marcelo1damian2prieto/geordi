package io.geordi.bootstrap.security.fixture;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.bootstrap.GeordiApplication;
import io.geordi.bootstrap.security.CredentialSelection;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.URI;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.web.server.LocalServerPort;

@GeordiIntegrationTest(classes = GeordiApplication.class,
        properties = {"geordi.modules.metrics.enabled=false", "geordi.modules.traces.enabled=false",
            "geordi.modules.logs.enabled=false", "geordi.modules.service-map.enabled=false",
            "geordi.modules.slos.enabled=false", "geordi.modules.alerts.enabled=false"},
        webEnvironment = org.springframework.boot.test.context.SpringBootTest.WebEnvironment.RANDOM_PORT)
class OidcIntegrationTest {
    @LocalServerPort
    private int port;

    @Test
    void discoversIssuerValidatesTlsAndCompletesBoundPkceLoginIntoCanonicalSession() throws Exception {
        HttpClient client = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NEVER).build();
        HttpResponse<String> login = send(client, URI.create(url("/oauth2/authorization/geordi")),
                "Authorization", "Bearer " + GeordiTestOidcFixture.instance().accessToken());
        assertThat(login.statusCode()).isEqualTo(302);
        URI authorizationEndpoint = URI.create(login.headers().firstValue("Location").orElseThrow());
        assertThat(authorizationEndpoint).isNotNull();

        HttpResponse<String> authorization = send(client, authorizationEndpoint);
        assertThat(authorization.statusCode()).isEqualTo(302);
        URI callback = URI.create(authorization.headers().firstValue("Location").orElseThrow());
        assertThat(callback.getHost()).isEqualTo("geordi.localhost");

        String browserBinding = cookieValue(login.headers().allValues("Set-Cookie"), "__Host-Geordi-OIDC");
        HttpResponse<String> completed = send(client,
                URI.create(url("/login/oauth2/code/geordi?" + callback.getRawQuery())),
                "Cookie", "__Host-Geordi-OIDC=" + browserBinding);
        assertThat(completed.statusCode()).isEqualTo(302);
        String sessionId = cookieValue(completed.headers().allValues("Set-Cookie"), CredentialSelection.SESSION_COOKIE);
        assertThat(completed.headers().allValues("Set-Cookie"))
                .anySatisfy(cookie -> assertThat(cookie).contains("__Host-Geordi-OIDC=; Path=/; Max-Age=0"));

        HttpResponse<String> identity = send(client, URI.create(url("/api/me")),
                "Cookie", CredentialSelection.SESSION_COOKIE + "=" + sessionId);
        assertThat(identity.statusCode()).isEqualTo(200);
        assertThat(identity.body()).contains("\"issuer\":\"" + GeordiTestOidcFixture.instance().issuer() + "\"")
                .contains("\"subject\":\"test-operator\"")
                .contains("\"authMode\":\"SESSION\"")
                .contains("\"permissions\":[\"alerts:acknowledge\",\"observability:read\"]");
    }

    private String url(String path) { return "http://localhost:" + port + path; }

    private static HttpResponse<String> send(HttpClient client, URI uri, String... headers) throws Exception {
        HttpRequest.Builder builder = HttpRequest.newBuilder(uri).GET();
        if (headers.length > 0) builder.headers(headers);
        HttpRequest request = builder.build();
        return client.send(request, HttpResponse.BodyHandlers.ofString());
    }

    private static String cookieValue(List<String> cookies, String name) {
        return cookies.stream()
                .filter(cookie -> cookie.startsWith(name + "="))
                .map(cookie -> cookie.substring(name.length() + 1, cookie.indexOf(';')))
                .findFirst().orElseThrow();
    }
}
