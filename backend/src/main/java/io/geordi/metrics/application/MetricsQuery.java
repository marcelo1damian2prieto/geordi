package io.geordi.metrics.application;

import io.geordi.metrics.domain.OperationalMetric;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.time.Duration;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;

public record MetricsQuery(
        ServiceIdentity service,
        TimeRange range,
        List<OperationalMetric> metrics,
        Duration resolution) {

    public MetricsQuery {
        Objects.requireNonNull(service, "service must not be null");
        Objects.requireNonNull(range, "range must not be null");
        if (metrics == null || metrics.isEmpty()) {
            throw new IllegalArgumentException("at least one metric is required");
        }
        metrics = metrics.stream().distinct().sorted(Comparator.comparing(Enum::name)).toList();
        Objects.requireNonNull(resolution, "resolution must not be null");
    }

    public static MetricsQuery of(ServiceIdentity service, TimeRange range, List<OperationalMetric> metrics) {
        return new MetricsQuery(service, range, metrics, range.resolution());
    }
}
