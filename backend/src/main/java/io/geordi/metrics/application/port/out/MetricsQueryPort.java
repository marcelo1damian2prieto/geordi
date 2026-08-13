package io.geordi.metrics.application.port.out;

import io.geordi.metrics.application.MetricsQuery;
import io.geordi.metrics.domain.MetricSeries;
import io.geordi.metrics.domain.ServiceIdentity;
import io.geordi.metrics.domain.TimeRange;
import java.util.List;

public interface MetricsQueryPort {

    List<ServiceIdentity> findServices(TimeRange range);

    List<MetricSeries> query(MetricsQuery query);
}
