package io.geordi.logs.application.port.out;

import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.domain.LogRecord;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.TimeRange;
import java.util.List;

public interface LogsQueryPort {

    List<ServiceIdentity> findServices(TimeRange range);

    List<LogRecord> search(LogSearchCriteria criteria);
}
