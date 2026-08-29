package io.geordi.alerts.application;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.alerts.application.port.out.AlertLifecycleRepository;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.application.port.out.SloLifecycleBindingPort;
import io.geordi.alerts.application.port.out.VersionedAlertLifecycle;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleBindingMismatchException;
import io.geordi.alerts.domain.AlertLifecycleProcessingOutcome;
import io.geordi.alerts.domain.AlertLifecycleTransitions;
import io.geordi.alerts.domain.NotificationDelivery;
import io.geordi.alerts.domain.NotificationDestination;
import io.geordi.alerts.domain.AlertPolicy;
import io.geordi.alerts.domain.AlertTransitionType;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import java.math.BigDecimal;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

class AlertLifecycleServiceTest {

    private static final Instant FIRST = Instant.parse("2026-08-27T14:00:00Z");
    private static final AlertPolicy POLICY = new AlertPolicy(
            "checkout-burn", "Checkout burn", null, true, "checkout-availability",
            new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, new BigDecimal("2")));

    @Test
    void callsCanonicalEvaluationExactlyOnceAcrossCasRetries() {
        AtomicInteger evaluationCalls = new AtomicInteger();
        AtomicInteger failedInserts = new AtomicInteger(3);
        InMemoryRepository repository = new InMemoryRepository() {
            @Override
            public boolean insertIfAbsent(AlertLifecycle lifecycle) {
                if (failedInserts.getAndDecrement() > 0) {
                    return false;
                }
                return super.insertIfAbsent(lifecycle);
            }
        };
        AlertLifecycleService service = service(repository, id -> {
            evaluationCalls.incrementAndGet();
            return evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST);
        });

        var result = service.evaluate(POLICY.id());

        assertThat(evaluationCalls).hasValue(1);
        assertThat(result.transition().type()).isEqualTo(AlertTransitionType.ALERT_STARTED);
        assertThat(result.outcome()).isEqualTo(AlertLifecycleProcessingOutcome.APPLIED);
    }

    @Test
    void boundsCasRetriesWithoutRepeatingCanonicalEvaluation() {
        AtomicInteger evaluationCalls = new AtomicInteger();
        AlertLifecycleRepository repository = new InMemoryRepository() {
            @Override
            public boolean insertIfAbsent(AlertLifecycle lifecycle) {
                return false;
            }
        };
        AlertLifecycleService service = service(repository, id -> {
            evaluationCalls.incrementAndGet();
            return evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST);
        });

        assertThatThrownBy(() -> service.evaluate(POLICY.id()))
                .isInstanceOf(AlertLifecycleConcurrencyException.class);
        assertThat(evaluationCalls).hasValue(1);
    }

    @Test
    void rejectsCanonicalEvaluationWithDifferentPolicyBindingBeforeWritingState() {
        InMemoryRepository repository = new InMemoryRepository();
        AlertLifecycleService service = service(repository, id -> new AlertEvaluation(
                "another-policy", POLICY.name(), POLICY.sloId(), POLICY.condition(),
                AlertEvaluationStatus.CONDITION_MET, null,
                evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST).evidence()));

        assertThatThrownBy(() -> service.evaluate(POLICY.id()))
                .isInstanceOf(AlertLifecycleBindingMismatchException.class);
        assertThat(repository.findAll()).isEmpty();
    }

    @Test
    void rejectsDisabledProcessingWhenStoredStateNoLongerMatchesTheCurrentSloBinding() {
        InMemoryRepository repository = new InMemoryRepository();
        AlertLifecycle firing = AlertLifecycleTransitions.apply(
                Optional.empty(), evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST), null).current();
        assertThat(repository.insertIfAbsent(firing)).isTrue();
        AlertEvaluation disabled = new AlertEvaluation(
                POLICY.id(), POLICY.name(), POLICY.sloId(), POLICY.condition(),
                AlertEvaluationStatus.UNAVAILABLE, io.geordi.alerts.domain.AlertUnavailableReason.DISABLED, null);
        SloLifecycleBindingPort changedBinding = ignored -> Optional.of(new SloLifecycleBindingPort.Binding(
                POLICY.sloId(), new ServiceIdentity("payments", "commerce", "production"),
                EvaluationWindow.PT15M));
        AlertLifecycleService service = new AlertLifecycleService(
                catalog(), ignored -> disabled, repository, changedBinding,
                Clock.fixed(FIRST.plusSeconds(10), ZoneOffset.UTC));

        assertThatThrownBy(() -> service.evaluate(POLICY.id()))
                .isInstanceOf(AlertLifecycleBindingMismatchException.class);
        assertThat(repository.findByPolicyId(POLICY.id()).orElseThrow().lifecycle()).isEqualTo(firing);
    }

    @Test
    void createsOneNotificationCandidateOnlyForTheWinningLifecycleTransition() {
        InMemoryRepository repository = new InMemoryRepository();
        AlertLifecycleService service = new AlertLifecycleService(
                catalog(), id -> evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST), repository, bindings(),
                Clock.fixed(FIRST.plusSeconds(10), ZoneOffset.UTC), transition -> Optional.of(
                        new NotificationDestination("operations-webhook", "fingerprint")));

        service.evaluate(POLICY.id());
        service.evaluate(POLICY.id());

        assertThat(repository.deliveries).singleElement().satisfies(delivery -> {
            assertThat(delivery.transition().type()).isEqualTo(AlertTransitionType.ALERT_STARTED);
            assertThat(delivery.destination().id()).isEqualTo("operations-webhook");
        });
    }

    @Test
    void concurrentStartsAndResolutionsEachProduceOneLogicalTransition() throws Exception {
        InMemoryRepository repository = new InMemoryRepository();
        AlertLifecycleService starts = service(
                repository, id -> evaluation(AlertEvaluationStatus.CONDITION_MET, FIRST));
        List<AlertLifecycleEvaluationResult> startResults = concurrently(20, starts);

        assertThat(startResults).filteredOn(result -> result.transition() != null)
                .singleElement().satisfies(result ->
                        assertThat(result.transition().type()).isEqualTo(AlertTransitionType.ALERT_STARTED));
        assertThat(startResults).filteredOn(result ->
                result.outcome() == AlertLifecycleProcessingOutcome.DUPLICATE_IGNORED).hasSize(19);

        AlertLifecycleService resolutions = service(
                repository, id -> evaluation(AlertEvaluationStatus.CONDITION_NOT_MET, FIRST.plusSeconds(1)));
        List<AlertLifecycleEvaluationResult> resolutionResults = concurrently(20, resolutions);

        assertThat(resolutionResults).filteredOn(result -> result.transition() != null)
                .singleElement().satisfies(result ->
                        assertThat(result.transition().type()).isEqualTo(AlertTransitionType.ALERT_RESOLVED));
        assertThat(repository.findByPolicyId(POLICY.id()).orElseThrow().lifecycle().state().name())
                .isEqualTo("INACTIVE");
    }

    private static List<AlertLifecycleEvaluationResult> concurrently(
            int count, AlertLifecycleEvaluationUseCase service) throws Exception {
        CountDownLatch ready = new CountDownLatch(count);
        CountDownLatch start = new CountDownLatch(1);
        try (var executor = Executors.newFixedThreadPool(count)) {
            List<Future<AlertLifecycleEvaluationResult>> futures = new ArrayList<>();
            for (int index = 0; index < count; index++) {
                futures.add(executor.submit(() -> {
                    ready.countDown();
                    start.await();
                    return service.evaluate(POLICY.id());
                }));
            }
            ready.await();
            start.countDown();
            List<AlertLifecycleEvaluationResult> results = new ArrayList<>();
            for (Future<AlertLifecycleEvaluationResult> future : futures) {
                results.add(future.get());
            }
            return results;
        }
    }

    private static AlertLifecycleService service(
            AlertLifecycleRepository repository, AlertEvaluationUseCase evaluations) {
        return new AlertLifecycleService(
                catalog(), evaluations, repository, bindings(),
                Clock.fixed(FIRST.plusSeconds(10), ZoneOffset.UTC));
    }

    private static SloLifecycleBindingPort bindings() {
        return ignored -> Optional.of(new SloLifecycleBindingPort.Binding(
                POLICY.sloId(), new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M));
    }

    private static AlertPolicyCatalog catalog() {
        return new AlertPolicyCatalog() {
            @Override
            public List<AlertPolicy> findAll() {
                return List.of(POLICY);
            }

            @Override
            public Optional<AlertPolicy> findById(String id) {
                return POLICY.id().equals(id) ? Optional.of(POLICY) : Optional.empty();
            }
        };
    }

    private static AlertEvaluation evaluation(AlertEvaluationStatus status, Instant evaluatedAt) {
        BurnRateEvidence evidence = new BurnRateEvidence(
                POLICY.sloId(), new ServiceIdentity("checkout", "commerce", "production"),
                EvaluationWindow.PT5M, new TimeRange(evaluatedAt.minusSeconds(300), evaluatedAt), evaluatedAt,
                status == AlertEvaluationStatus.CONDITION_MET ? new BigDecimal("3") : new BigDecimal("0.5"), null);
        return new AlertEvaluation(
                POLICY.id(), POLICY.name(), POLICY.sloId(), POLICY.condition(), status, null, evidence);
    }

    private static class InMemoryRepository implements AlertLifecycleRepository {

        private final ConcurrentHashMap<String, VersionedAlertLifecycle> records = new ConcurrentHashMap<>();
        private final List<NotificationDelivery> deliveries = new ArrayList<>();

        @Override
        public Optional<VersionedAlertLifecycle> findByPolicyId(String policyId) {
            return Optional.ofNullable(records.get(policyId));
        }

        @Override
        public List<VersionedAlertLifecycle> findAll() {
            return List.copyOf(records.values());
        }

        @Override
        public boolean insertIfAbsent(AlertLifecycle lifecycle) {
            return records.putIfAbsent(
                    lifecycle.policyId(), new VersionedAlertLifecycle(lifecycle, 0)) == null;
        }

        @Override
        public boolean replaceIfVersionMatches(AlertLifecycle lifecycle, long expectedVersion) {
            final boolean[] replaced = new boolean[1];
            records.computeIfPresent(lifecycle.policyId(), (key, value) -> {
                if (value.version() == expectedVersion) {
                    replaced[0] = true;
                    return new VersionedAlertLifecycle(lifecycle, expectedVersion + 1);
                }
                return value;
            });
            return replaced[0];
        }

        @Override
        public boolean commit(
                AlertLifecycle lifecycle, Optional<Long> expectedVersion, Optional<NotificationDelivery> delivery) {
            boolean committed = expectedVersion.map(version -> replaceIfVersionMatches(lifecycle, version))
                    .orElseGet(() -> insertIfAbsent(lifecycle));
            if (committed) {
                delivery.ifPresent(deliveries::add);
            }
            return committed;
        }
    }
}
