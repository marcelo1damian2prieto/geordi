package io.geordi.metrics.domain;

import java.util.Comparator;
import java.util.List;
import java.util.Objects;

public record MetricSeries(OperationalMetric metric, List<MetricPoint> points) {

    public MetricSeries {
        Objects.requireNonNull(metric, "metric must not be null");
        points = points == null ? List.of() : points.stream()
                .sorted(Comparator.comparing(MetricPoint::timestamp))
                .toList();
    }

    public String unit() {
        return metric.unit();
    }
}
