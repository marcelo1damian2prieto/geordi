package io.geordi.traces.application.port.out;

import io.geordi.traces.application.TraceSearchCriteria;
import io.geordi.traces.domain.ServiceIdentity;
import io.geordi.traces.domain.TimeRange;
import io.geordi.traces.domain.TraceDetail;
import io.geordi.traces.domain.TraceId;
import io.geordi.traces.domain.TraceSummary;
import java.util.List;
import java.util.Optional;

public interface TraceQueryPort {

    List<ServiceIdentity> findServices(TimeRange range);

    List<TraceSummary> search(TraceSearchCriteria criteria);

    Optional<TraceDetail> findTrace(TraceId traceId);
}
