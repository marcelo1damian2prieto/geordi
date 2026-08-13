package io.geordi.traces.adapter.spring;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;
import io.geordi.traces.TracesPlatformModule;
import io.geordi.traces.adapter.out.telemetry.ObservedTraceQueryAdapter;
import io.geordi.traces.adapter.out.tempo.TempoProperties;
import io.geordi.traces.adapter.out.tempo.TempoTraceAdapter;
import io.geordi.traces.application.TraceQueryService;
import io.geordi.traces.application.port.out.TraceBackendProbe;
import java.util.function.Supplier;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

@Configuration(proxyBeanMethods = false)
public class TracesModuleConfiguration {

    @Bean
    PlatformModule tracesPlatformModule(ObjectProvider<TraceBackendProbe> probeProvider) {
        return new TracesPlatformModule(() -> probeProvider
                .getIfAvailable((Supplier<TraceBackendProbe>) () -> () -> false)
                .isQueryable() ? ModuleStatus.UP : ModuleStatus.DOWN);
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnProperty(
            prefix = "geordi.modules.traces",
            name = "enabled",
            havingValue = "true",
            matchIfMissing = true)
    @EnableConfigurationProperties(TempoProperties.class)
    static class EnabledTracesConfiguration {

        @Bean
        TempoTraceAdapter tempoTraceAdapter(TempoProperties properties, ObjectMapper objectMapper) {
            SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
            requestFactory.setConnectTimeout(properties.connectTimeout());
            requestFactory.setReadTimeout(properties.readTimeout());
            RestClient client = RestClient.builder()
                    .baseUrl(properties.baseUrl().toString())
                    .requestFactory(requestFactory)
                    .build();
            return new TempoTraceAdapter(client, objectMapper);
        }

        @Bean
        @Primary
        ObservedTraceQueryAdapter observedTraceQueryAdapter(TempoTraceAdapter adapter) {
            return new ObservedTraceQueryAdapter(adapter, adapter);
        }

        @Bean
        TraceQueryService traceQueryService(ObservedTraceQueryAdapter adapter) {
            return new TraceQueryService(adapter);
        }
    }
}
