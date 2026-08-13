package io.geordi.metrics.adapter.in.web;

import io.geordi.metrics.application.MetricsOverview;
import io.geordi.metrics.application.MetricsQueryService;
import io.geordi.metrics.domain.MetricPoint;
import io.geordi.metrics.domain.MetricSeries;
import io.geordi.metrics.domain.OperationalMetric;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.time.Instant;
import java.util.List;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;

@RestController
@ConditionalOnProperty(
        prefix = "geordi.modules.metrics", name = "enabled", havingValue = "true", matchIfMissing = true)
@RequestMapping("/api/metrics")
public class MetricsController {

    private final MetricsQueryService service;

    public MetricsController(MetricsQueryService service) {
        this.service = service;
    }

    @GetMapping("/services")
    public ServicesResponse services(
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant from,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant to) {
        return new ServicesResponse(service.services(new TimeRange(from, to)));
    }

    @GetMapping("/overview")
    public OverviewResponse overview(
            @RequestParam String serviceName,
            @RequestParam(required = false) String serviceNamespace,
            @RequestParam String environment,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant from,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant to) {
        MetricsOverview overview = service.overview(
                new ServiceIdentity(serviceName, serviceNamespace, environment), new TimeRange(from, to));
        return OverviewResponse.from(overview);
    }

    @GetMapping("/series")
    public SeriesResponse series(
            @RequestParam String serviceName,
            @RequestParam(required = false) String serviceNamespace,
            @RequestParam String environment,
            @RequestParam List<OperationalMetric> metric,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant from,
            @RequestParam @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME) Instant to) {
        ServiceIdentity identity = new ServiceIdentity(serviceName, serviceNamespace, environment);
        TimeRange range = new TimeRange(from, to);
        return new SeriesResponse(identity, new RangeResponse(range.from(), range.to()),
                service.series(identity, range, metric).stream().map(MetricSeriesResponse::from).toList());
    }

    public record ServicesResponse(List<ServiceIdentity> services) {
    }

    public record OverviewResponse(
            ServiceIdentity service, RangeResponse range, List<MetricValueResponse> values) {

        static OverviewResponse from(MetricsOverview overview) {
            return new OverviewResponse(overview.service(),
                    new RangeResponse(overview.range().from(), overview.range().to()),
                    overview.values().stream().map(MetricValueResponse::from).toList());
        }
    }

    public record SeriesResponse(
            ServiceIdentity service, RangeResponse range, List<MetricSeriesResponse> series) {
    }

    public record RangeResponse(String from, String to) {

        RangeResponse(Instant from, Instant to) {
            this(from.toString(), to.toString());
        }
    }

    public record MetricValueResponse(
            OperationalMetric metric, String unit, double value, String timestamp) {

        static MetricValueResponse from(MetricsOverview.LatestMetricValue value) {
            return new MetricValueResponse(value.metric(), value.unit(),
                    value.point().value(), value.point().timestamp().toString());
        }
    }

    public record MetricSeriesResponse(
            OperationalMetric metric, String unit, List<PointResponse> points) {

        static MetricSeriesResponse from(MetricSeries series) {
            return new MetricSeriesResponse(series.metric(), series.unit(),
                    series.points().stream().map(PointResponse::from).toList());
        }
    }

    public record PointResponse(String timestamp, double value) {

        static PointResponse from(MetricPoint point) {
            return new PointResponse(point.timestamp().toString(), point.value());
        }
    }
}
