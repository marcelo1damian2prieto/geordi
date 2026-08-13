package io.geordi.metrics.application;

import io.geordi.metrics.application.port.out.MetricsQueryPort;
import io.geordi.metrics.domain.MetricPoint;
import io.geordi.metrics.domain.MetricSeries;
import io.geordi.metrics.domain.OperationalMetric;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.Objects;
import java.util.stream.IntStream;

public final class MetricsQueryService {

    private static final int MAXIMUM_POINTS_PER_SERIES = 300;

    private final MetricsQueryPort port;

    public MetricsQueryService(MetricsQueryPort port) {
        this.port = Objects.requireNonNull(port, "metrics query port must not be null");
    }

    public List<ServiceIdentity> services(TimeRange range) {
        return port.findServices(range).stream()
                .distinct()
                .sorted(Comparator.comparing(ServiceIdentity::name)
                        .thenComparing(service -> Objects.toString(service.namespace(), ""))
                        .thenComparing(ServiceIdentity::environment))
                .toList();
    }

    public List<MetricSeries> series(
            ServiceIdentity service, TimeRange range, List<OperationalMetric> metrics) {
        return port.query(MetricsQuery.of(service, range, metrics)).stream()
                .map(MetricsQueryService::limitPoints)
                .sorted(Comparator.comparing(series -> series.metric().name()))
                .toList();
    }

    public MetricsOverview overview(ServiceIdentity service, TimeRange range) {
        List<MetricSeries> series = series(service, range, Arrays.asList(OperationalMetric.values()));
        List<MetricsOverview.LatestMetricValue> values = series.stream()
                .filter(item -> !item.points().isEmpty())
                .map(item -> new MetricsOverview.LatestMetricValue(
                        item.metric(), item.unit(), item.points().getLast()))
                .toList();
        return new MetricsOverview(service, range, values);
    }

    private static MetricSeries limitPoints(MetricSeries series) {
        if (series.points().size() <= MAXIMUM_POINTS_PER_SERIES) {
            return series;
        }
        int lastIndex = series.points().size() - 1;
        List<MetricPoint> selected = IntStream
                .range(0, MAXIMUM_POINTS_PER_SERIES)
                .map(index -> Math.toIntExact(Math.round(
                        index * (double) lastIndex / (MAXIMUM_POINTS_PER_SERIES - 1))))
                .mapToObj(series.points()::get)
                .toList();
        return new MetricSeries(series.metric(), selected);
    }
}
