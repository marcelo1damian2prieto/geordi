package io.geordi.selfobservability.adapter.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import io.geordi.core.application.security.SecurityObservation;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.LongCounterBuilder;
import io.opentelemetry.api.metrics.Meter;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

class SecurityObservationTest {
    @Test
    void emitsExactlyTheFourClosedDimensionsAtTheOwningDecisionBoundary() {
        var meter = mock(Meter.class);
        var authentication = counter(meter, "geordi.security.authentication.attempts");
        var authorization = counter(meter, "geordi.security.authorization.decisions");
        var observed = new SecurityObservationAdapter(meter);
        observed.authentication(SecurityObservation.Mechanism.BEARER, SecurityObservation.Result.SUCCESS,
                SecurityObservation.Reason.VALID, SecurityObservation.Endpoint.READ);
        observed.authorization(SecurityObservation.Mechanism.SESSION, SecurityObservation.Result.DENIED,
                SecurityObservation.Reason.PERMISSION, SecurityObservation.Endpoint.ACKNOWLEDGE);
        var attributes = ArgumentCaptor.forClass(Attributes.class);
        verify(authentication).add(eq(1L), attributes.capture());
        assertThat(attributes.getValue().asMap()).hasSize(4);
        assertThat(attributes.getValue().asMap().values()).containsExactlyInAnyOrder("bearer", "success", "valid", "read");
        verify(authorization).add(eq(1L), any(Attributes.class));
        assertThat(SecurityObservation.Endpoint.values()).extracting(Enum::name).containsExactly(
                "READ", "ACKNOWLEDGE", "EVALUATE", "ME", "LOGIN", "CALLBACK", "CSRF", "LOGOUT", "PROBE", "DENIED");
        assertThat(SecurityObservation.Mechanism.values()).extracting(Enum::name)
                .containsExactly("NONE", "AMBIGUOUS", "SESSION", "BEARER");
        assertThat(SecurityObservation.Result.values()).extracting(Enum::name)
                .containsExactly("SUCCESS", "FAILURE", "ALLOWED", "DENIED");
        assertThat(SecurityObservation.Reason.values()).extracting(Enum::name).containsExactly(
                "VALID", "MISSING", "INVALID", "DEPENDENCY", "AMBIGUOUS", "CAPACITY", "PERMISSION", "CSRF", "ORIGIN", "ROUTE");
    }

    private static LongCounter counter(Meter meter, String name) {
        var counter = mock(LongCounter.class);
        var builder = mock(LongCounterBuilder.class);
        when(meter.counterBuilder(name)).thenReturn(builder);
        when(builder.build()).thenReturn(counter);
        return counter;
    }
}
