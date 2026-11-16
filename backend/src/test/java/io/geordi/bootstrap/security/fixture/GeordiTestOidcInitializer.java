package io.geordi.bootstrap.security.fixture;

import java.util.Map;
import org.springframework.boot.web.client.RestTemplateCustomizer;
import org.springframework.context.ApplicationContextInitializer;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.core.env.MapPropertySource;

/** Installs one real HTTPS test issuer before Spring builds the security composition. */
public final class GeordiTestOidcInitializer implements ApplicationContextInitializer<ConfigurableApplicationContext> {
    @Override
    public void initialize(ConfigurableApplicationContext context) {
        GeordiTestOidcFixture fixture = GeordiTestOidcFixture.instance();
        context.getEnvironment().getPropertySources().addFirst(new MapPropertySource("geordiTestOidc", Map.ofEntries(
                Map.entry("geordi.security.issuer", fixture.issuer()),
                Map.entry("geordi.security.api-audience", "geordi-api"),
                Map.entry("geordi.security.browser-client-id", "geordi-browser"),
                Map.entry("geordi.security.browser-client-secret-file", fixture.secretFile().toString()),
                Map.entry("geordi.security.public-base-url", "https://geordi.localhost"),
                Map.entry("geordi.security.grant-claim", "geordi_permissions"),
                Map.entry("geordi.security.grant-mapping.VIEWER[0]", "observability:read"),
                Map.entry("geordi.security.grant-mapping.OPERATOR[0]", "observability:read"),
                Map.entry("geordi.security.grant-mapping.OPERATOR[1]", "alerts:acknowledge"),
                Map.entry("geordi.security.grant-mapping.EVALUATOR[0]", "observability:read"),
                Map.entry("geordi.security.grant-mapping.EVALUATOR[1]", "alerts:evaluate"))));
        if (!context.getBeanFactory().containsSingleton("geordiTestBearerCustomizer")) {
            context.getBeanFactory().registerSingleton("geordiTestBearerCustomizer", (RestTemplateCustomizer) template ->
                    template.getInterceptors().add((request, body, execution) -> {
                        if (!request.getHeaders().containsKey("Authorization")
                                && !request.getHeaders().containsKey("Cookie")) {
                            request.getHeaders().setBearerAuth(fixture.accessToken());
                        }
                        return execution.execute(request, body);
                    }));
        }
    }
}
