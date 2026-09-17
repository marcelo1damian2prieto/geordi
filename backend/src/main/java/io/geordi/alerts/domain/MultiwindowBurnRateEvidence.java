package io.geordi.alerts.domain;

import java.time.Instant;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

public final class MultiwindowBurnRateEvidence implements AlertEvidence {

    private static final int MINIMUM_OBSERVATIONS = 2;
    private static final int MAXIMUM_OBSERVATIONS = 4;

    private final String sloId;
    private final ServiceIdentity service;
    private final EvaluationWindow configuredSloWindow;
    private final Instant evaluatedAt;
    private final List<WindowBurnRateObservation> observations;

    private MultiwindowBurnRateEvidence(
            String sloId,
            ServiceIdentity service,
            EvaluationWindow configuredSloWindow,
            Instant evaluatedAt,
            List<WindowBurnRateObservation> observations) {
        this.sloId = sloId;
        this.service = service;
        this.configuredSloWindow = configuredSloWindow;
        this.evaluatedAt = evaluatedAt;
        this.observations = observations;
    }

    public static MultiwindowBurnRateEvidence of(
            String sloId,
            ServiceIdentity service,
            EvaluationWindow configuredSloWindow,
            Instant evaluatedAt,
            Set<AlertObservationWindow> requestedWindows,
            List<WindowBurnRateObservation> observations) {
        requireText(sloId, "multiwindow evidence SLO id must not be blank");
        Objects.requireNonNull(service, "multiwindow evidence service must not be null");
        Objects.requireNonNull(configuredSloWindow, "configured SLO provenance window must not be null");
        Objects.requireNonNull(evaluatedAt, "multiwindow evidence evaluation time must not be null");
        Objects.requireNonNull(requestedWindows, "requested alert observation windows must not be null");
        Objects.requireNonNull(observations, "multiwindow observations must not be null");
        if (requestedWindows.size() < MINIMUM_OBSERVATIONS || requestedWindows.size() > MAXIMUM_OBSERVATIONS
                || requestedWindows.stream().anyMatch(Objects::isNull)) {
            throw new IllegalArgumentException("multiwindow evidence requires two through four requested windows");
        }
        if (observations.size() < MINIMUM_OBSERVATIONS || observations.size() > MAXIMUM_OBSERVATIONS
                || observations.stream().anyMatch(Objects::isNull)) {
            throw new IllegalArgumentException("multiwindow evidence requires two through four observations");
        }
        Set<AlertObservationWindow> returnedWindows = new LinkedHashSet<>();
        for (WindowBurnRateObservation observation : observations) {
            if (!returnedWindows.add(observation.observationWindow())) {
                throw new IllegalArgumentException("multiwindow evidence contains a duplicate observation");
            }
            if (!observation.range().to().equals(evaluatedAt)
                    || !observation.range().from().equals(evaluatedAt.minus(observation.observationWindow().duration()))) {
                throw new IllegalArgumentException("multiwindow observation does not share the canonical evaluation time");
            }
        }
        if (!returnedWindows.equals(Set.copyOf(requestedWindows))) {
            throw new IllegalArgumentException("multiwindow evidence does not match the requested observation windows");
        }
        List<WindowBurnRateObservation> canonical = observations.stream()
                .sorted(Comparator.comparingInt(value -> value.observationWindow().canonicalRank()))
                .toList();
        return new MultiwindowBurnRateEvidence(
                sloId, service, configuredSloWindow, evaluatedAt, canonical);
    }

    @Override
    public String sloId() {
        return sloId;
    }

    @Override
    public ServiceIdentity service() {
        return service;
    }

    @Override
    public EvaluationWindow configuredSloWindow() {
        return configuredSloWindow;
    }

    @Override
    public Instant evaluatedAt() {
        return evaluatedAt;
    }

    public List<WindowBurnRateObservation> observations() {
        return observations;
    }

    public Set<AlertObservationWindow> observationWindows() {
        LinkedHashSet<AlertObservationWindow> windows = new LinkedHashSet<>();
        observations.forEach(value -> windows.add(value.observationWindow()));
        return Collections.unmodifiableSet(windows);
    }

    public WindowBurnRateObservation observation(AlertObservationWindow window) {
        Objects.requireNonNull(window, "alert observation window must not be null");
        return observations.stream()
                .filter(value -> value.observationWindow() == window)
                .findFirst()
                .orElseThrow(() -> new IllegalArgumentException("multiwindow evidence is missing an observation"));
    }

    @Override
    public boolean equals(Object other) {
        if (this == other) {
            return true;
        }
        if (!(other instanceof MultiwindowBurnRateEvidence that)) {
            return false;
        }
        return sloId.equals(that.sloId)
                && service.equals(that.service)
                && configuredSloWindow == that.configuredSloWindow
                && evaluatedAt.equals(that.evaluatedAt)
                && observations.equals(that.observations);
    }

    @Override
    public int hashCode() {
        return Objects.hash(sloId, service, configuredSloWindow, evaluatedAt, observations);
    }

    @Override
    public String toString() {
        return "MultiwindowBurnRateEvidence[sloId=" + sloId
                + ", service=" + service
                + ", configuredSloWindow=" + configuredSloWindow
                + ", evaluatedAt=" + evaluatedAt
                + ", observations=" + observations + ']';
    }

    private static void requireText(String value, String message) {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException(message);
        }
    }
}
