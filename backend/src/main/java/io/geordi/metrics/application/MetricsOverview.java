package io.geordi.metrics.application;

import io.geordi.metrics.domain.MetricPoint;
import io.geordi.metrics.domain.OperationalMetric;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.util.List;

public record MetricsOverview(
        ServiceIdentity service,
        TimeRange range,
        List<LatestMetricValue> values) {

    public MetricsOverview {
        values = List.copyOf(values);
    }

    public record LatestMetricValue(OperationalMetric metric, String unit, MetricPoint point) {
    }
}
