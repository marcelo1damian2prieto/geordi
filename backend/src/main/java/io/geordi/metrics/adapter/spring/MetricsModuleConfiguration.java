package io.geordi.metrics.adapter.spring;

import io.geordi.core.module.ModuleStatus;
import io.geordi.core.module.PlatformModule;
import io.geordi.metrics.MetricsPlatformModule;
import io.geordi.metrics.adapter.out.telemetry.ObservedMetricsQueryAdapter;
import io.geordi.metrics.adapter.out.victoriametrics.VictoriaMetricsAdapter;
import io.geordi.metrics.adapter.out.victoriametrics.VictoriaMetricsProperties;
import io.geordi.metrics.application.MetricsQueryService;
import io.geordi.metrics.application.port.out.MetricsBackendProbe;
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
public class MetricsModuleConfiguration {

    @Bean
    PlatformModule metricsPlatformModule(ObjectProvider<MetricsBackendProbe> probeProvider) {
        return new MetricsPlatformModule(() -> probeProvider.getIfAvailable((Supplier<MetricsBackendProbe>) () -> () -> false)
                .isQueryable() ? ModuleStatus.UP : ModuleStatus.DOWN);
    }

    @Configuration(proxyBeanMethods = false)
    @ConditionalOnProperty(
            prefix = "geordi.modules.metrics",
            name = "enabled",
            havingValue = "true",
            matchIfMissing = true)
    @EnableConfigurationProperties(VictoriaMetricsProperties.class)
    static class EnabledMetricsConfiguration {

        @Bean
        VictoriaMetricsAdapter victoriaMetricsAdapter(VictoriaMetricsProperties properties) {
            SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
            requestFactory.setConnectTimeout(properties.connectTimeout());
            requestFactory.setReadTimeout(properties.readTimeout());
            RestClient client = RestClient.builder()
                    .baseUrl(properties.baseUrl().toString())
                    .requestFactory(requestFactory)
                    .build();
            return new VictoriaMetricsAdapter(client);
        }

        @Bean
        @Primary
        ObservedMetricsQueryAdapter observedMetricsQueryAdapter(VictoriaMetricsAdapter adapter) {
            return new ObservedMetricsQueryAdapter(adapter, adapter);
        }

        @Bean
        MetricsQueryService metricsQueryService(ObservedMetricsQueryAdapter adapter) {
            return new MetricsQueryService(adapter);
        }
    }
}
