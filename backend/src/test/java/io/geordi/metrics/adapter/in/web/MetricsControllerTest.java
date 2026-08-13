package io.geordi.metrics.adapter.in.web;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import io.geordi.metrics.application.MetricsQuery;
import io.geordi.metrics.application.MetricsQueryService;
import io.geordi.metrics.application.port.out.MetricsQueryPort;
import io.geordi.metrics.domain.MetricPoint;
import io.geordi.metrics.domain.MetricSeries;
import io.geordi.metrics.domain.OperationalMetric;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class MetricsControllerTest {

    private MockMvc mvc;

    @BeforeEach
    void setUp() {
        MetricsQueryPort port = new MetricsQueryPort() {
            @Override
            public List<ServiceIdentity> findServices(TimeRange range) {
                return List.of(new ServiceIdentity("orders", "shop", "dev"));
            }

            @Override
            public List<MetricSeries> query(MetricsQuery query) {
                return query.metrics().stream().map(metric -> new MetricSeries(metric,
                        List.of(new MetricPoint(Instant.parse("2026-08-13T11:59:00Z"), 12.5)))).toList();
            }
        };
        mvc = MockMvcBuilders.standaloneSetup(new MetricsController(new MetricsQueryService(port)))
                .setControllerAdvice(new MetricsExceptionHandler()).build();
    }

    @Test
    void exposesCompositeServiceDiscoveryContract() throws Exception {
        mvc.perform(get("/api/metrics/services")
                        .param("from", "2026-08-13T11:45:00Z")
                        .param("to", "2026-08-13T12:00:00Z"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.services[0].name").value("orders"))
                .andExpect(jsonPath("$.services[0].namespace").value("shop"))
                .andExpect(jsonPath("$.services[0].environment").value("dev"));
    }

    @Test
    void exposesOverviewAndRepeatedMetricSeriesWithoutProviderSyntax() throws Exception {
        mvc.perform(get("/api/metrics/overview")
                        .param("serviceName", "orders")
                        .param("serviceNamespace", "shop")
                        .param("environment", "dev")
                        .param("from", "2026-08-13T11:45:00Z")
                        .param("to", "2026-08-13T12:00:00Z"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.values.length()").value(9))
                .andExpect(jsonPath("$.values[0].metric").exists())
                .andExpect(jsonPath("$.values[0].unit").exists());

        mvc.perform(get("/api/metrics/series")
                        .param("serviceName", "orders")
                        .param("serviceNamespace", "shop")
                        .param("environment", "dev")
                        .param("metric", OperationalMetric.JVM_MEMORY_USED.name())
                        .param("metric", OperationalMetric.HTTP_ERROR_RATE.name())
                        .param("from", "2026-08-13T11:45:00Z")
                        .param("to", "2026-08-13T12:00:00Z"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.series.length()").value(2))
                .andExpect(jsonPath("$.range.from").value("2026-08-13T11:45:00Z"));
    }

    @Test
    void rejectsUnsupportedMetricsAndInvalidRanges() throws Exception {
        mvc.perform(get("/api/metrics/series")
                        .param("serviceName", "orders")
                        .param("environment", "dev")
                        .param("metric", "raw_promql")
                        .param("from", "2026-08-13T12:00:00Z")
                        .param("to", "2026-08-13T11:45:00Z"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.detail").value("Invalid metrics request"));
    }
}
