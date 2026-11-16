package io.geordi.selfobservability.adapter.security;

import io.geordi.core.application.security.SecurityObservation;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.common.Attributes;
import io.opentelemetry.api.metrics.LongCounter;
import io.opentelemetry.api.metrics.Meter;
import java.util.Locale;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class SecurityObservationAdapter implements SecurityObservation {
    private static final Logger LOGGER = LoggerFactory.getLogger(SecurityObservationAdapter.class);
    private final LongCounter authentications;
    private final LongCounter authorizations;

    public SecurityObservationAdapter() {
        this(GlobalOpenTelemetry.getMeter("io.geordi.security"));
    }

    public SecurityObservationAdapter(Meter meter) {
        authentications = meter.counterBuilder("geordi.security.authentication.attempts").build();
        authorizations = meter.counterBuilder("geordi.security.authorization.decisions").build();
    }

    @Override
    public void authentication(Mechanism mechanism, Result result, Reason reason, Endpoint endpoint) {
        record(authentications, "authentication", mechanism, result, reason, endpoint);
    }

    @Override
    public void authorization(Mechanism mechanism, Result result, Reason reason, Endpoint endpoint) {
        record(authorizations, "authorization", mechanism, result, reason, endpoint);
    }

    private static void record(LongCounter counter, String event, Mechanism mechanism, Result result,
            Reason reason, Endpoint endpoint) {
        counter.add(1, Attributes.builder()
                .put("geordi.security.mechanism", mechanism.name().toLowerCase(Locale.ROOT))
                .put("geordi.security.result", result.name().toLowerCase(Locale.ROOT))
                .put("geordi.security.reason", reason.name().toLowerCase(Locale.ROOT))
                .put("geordi.security.endpoint", endpoint.name().toLowerCase(Locale.ROOT)).build());
        LOGGER.atInfo().addKeyValue("security.event", event)
                .addKeyValue("security.mechanism", mechanism.name())
                .addKeyValue("security.result", result.name())
                .addKeyValue("security.reason", reason.name())
                .addKeyValue("security.endpoint", endpoint.name()).log("Security decision");
    }
}
