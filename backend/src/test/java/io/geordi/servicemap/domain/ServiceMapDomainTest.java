package io.geordi.servicemap.domain;

import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Instant;
import org.junit.jupiter.api.Test;

class ServiceMapDomainTest {

    @Test
    void rejectsInvalidIdentityRangeAndIdentifiers() {
        assertThatThrownBy(() -> new ServiceIdentity(" ", null, "dev"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new ServiceIdentity("orders", null, " "))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new TimeRange(
                Instant.parse("2026-08-20T00:00:00Z"), Instant.parse("2026-08-20T06:00:00.001Z")))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new TraceId("ABC"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> new SpanId("0123"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
