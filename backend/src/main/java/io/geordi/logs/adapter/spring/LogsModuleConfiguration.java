package io.geordi.logs.adapter.spring;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;
import io.geordi.logs.LogsPlatformModule;
import io.geordi.logs.adapter.out.loki.LokiLogsAdapter;
import io.geordi.logs.adapter.out.loki.LokiProperties;
import io.geordi.logs.adapter.out.telemetry.ObservedLogsQueryAdapter;
import io.geordi.logs.application.LogsQueryService;
import io.geordi.logs.application.port.out.LogsBackendProbe;
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
public class LogsModuleConfiguration {

    @Bean
    PlatformModule logsPlatformModule(ObjectProvider<LogsBackendProbe> probeProvider) {
        return new LogsPlatformModule(() -> probeProvider
                .getIfAvailable((Supplier<LogsBackendProbe>) () -> () -> false)
                .isQueryable() ? ModuleStatus.UP : ModuleStatus.DOWN);
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnProperty(
            prefix = "geordi.modules.logs",
            name = "enabled",
            havingValue = "true",
            matchIfMissing = true)
    @EnableConfigurationProperties(LokiProperties.class)
    static class EnabledLogsConfiguration {

        @Bean
        LokiLogsAdapter lokiLogsAdapter(LokiProperties properties, ObjectMapper objectMapper) {
            SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
            requestFactory.setConnectTimeout(properties.connectTimeout());
            requestFactory.setReadTimeout(properties.readTimeout());
            RestClient client = RestClient.builder()
                    .baseUrl(properties.baseUrl().toString())
                    .requestFactory(requestFactory)
                    .build();
            return new LokiLogsAdapter(client, objectMapper);
        }

        @Bean
        @Primary
        ObservedLogsQueryAdapter observedLogsQueryAdapter(LokiLogsAdapter adapter) {
            return new ObservedLogsQueryAdapter(adapter, adapter);
        }

        @Bean
        LogsQueryService logsQueryService(ObservedLogsQueryAdapter adapter) {
            return new LogsQueryService(adapter);
        }
    }
}
