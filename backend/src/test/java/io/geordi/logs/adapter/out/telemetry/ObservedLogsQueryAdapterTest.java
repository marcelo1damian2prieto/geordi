package io.geordi.logs.adapter.out.telemetry;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.logs.application.LogSearchCriteria;
import io.geordi.logs.application.port.out.LogsBackendProbe;
import io.geordi.logs.application.port.out.LogsQueryPort;
import io.geordi.logs.domain.LogRecord;
import io.geordi.logs.domain.ServiceIdentity;
import io.geordi.logs.domain.TimeRange;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.Test;

class ObservedLogsQueryAdapterTest {

    @Test
    void preservesResultsAndTurnsProbeExceptionsIntoDown() {
        ServiceIdentity identity = new ServiceIdentity("orders", null, "dev");
        LogsQueryPort query = new LogsQueryPort() {
            @Override
            public List<ServiceIdentity> findServices(TimeRange range) {
                return List.of(identity);
            }

            @Override
            public List<LogRecord> search(LogSearchCriteria criteria) {
                return List.of();
            }
        };
        LogsBackendProbe probe = () -> {
            throw new IllegalStateException("provider detail");
        };
        ObservedLogsQueryAdapter adapter = new ObservedLogsQueryAdapter(query, probe);

        assertThat(adapter.findServices(new TimeRange(
                Instant.parse("2026-08-14T11:45:00Z"), Instant.parse("2026-08-14T12:00:00Z"))))
                .containsExactly(identity);
        assertThat(adapter.isQueryable()).isFalse();
    }
}
