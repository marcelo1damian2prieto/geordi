package io.geordi.alerts.adapter.in.worker;

import static org.assertj.core.api.Assertions.assertThat;

import io.geordi.alerts.application.AlertSchedulingSettings;
import io.geordi.alerts.application.AlertLifecycleEvaluationInProgressException;
import io.geordi.alerts.application.AlertLifecycleEvaluationUseCase;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertConditionType;
import io.geordi.alerts.domain.AlertPolicy;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.math.BigDecimal;
import java.time.Duration;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

class AlertEvaluationSchedulerTest {
    private static final Duration INTERVAL = Duration.ofSeconds(10);
    private static final Duration SHUTDOWN_GRACE_PERIOD = Duration.ofSeconds(1);
    private static final Method SUBMIT = submitMethod();

    @Test
    void startsOnlyEnabledPolicies() throws Exception {
        CountDownLatch evaluated = new CountDownLatch(1);
        AtomicInteger disabledCalls = new AtomicInteger();
        AtomicInteger enabledCalls = new AtomicInteger();
        AlertLifecycleEvaluationUseCase evaluations = policyId -> {
            if (policyId.equals("disabled-policy")) {
                disabledCalls.incrementAndGet();
            }
            if (policyId.equals("enabled-policy")) {
                enabledCalls.incrementAndGet();
                evaluated.countDown();
            }
            return null;
        };
        AlertEvaluationScheduler scheduler = scheduler(
                catalog(policy("disabled-policy", false), policy("enabled-policy", true)),
                evaluations,
                properties(1, 1));
        try {
            scheduler.start();

            assertThat(evaluated.await(5, TimeUnit.SECONDS)).isTrue();
            assertThat(enabledCalls).hasValue(1);
            assertThat(disabledCalls).hasValue(0);
        } finally {
            scheduler.close();
        }
    }

    @Test
    void suppressesDuplicateSubmissionWhileThePolicyIsAlreadyPending() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        CountDownLatch finished = new CountDownLatch(1);
        AtomicInteger calls = new AtomicInteger();
        AlertEvaluationScheduler scheduler = scheduler(
                catalog(policy("checkout-burn", true)),
                policyId -> {
                    calls.incrementAndGet();
                    entered.countDown();
                    try {
                        assertThat(release.await(5, TimeUnit.SECONDS)).isTrue();
                    } catch (InterruptedException exception) {
                        Thread.currentThread().interrupt();
                    } finally {
                        finished.countDown();
                    }
                    return null;
                },
                properties(1, 1));
        try {
            submit(scheduler, "checkout-burn");
            assertThat(entered.await(5, TimeUnit.SECONDS)).isTrue();

            submit(scheduler, "checkout-burn");

            release.countDown();
            assertThat(finished.await(5, TimeUnit.SECONDS)).isTrue();
            assertThat(calls).hasValue(1);
        } finally {
            release.countDown();
            scheduler.close();
        }
    }

    @Test
    void clearsPendingStateAfterAnInProgressEvaluationSignal() throws Exception {
        CountDownLatch secondAttempt = new CountDownLatch(1);
        AtomicInteger calls = new AtomicInteger();
        AlertEvaluationScheduler scheduler = scheduler(
                catalog(policy("checkout-burn", true)),
                policyId -> {
                    if (calls.incrementAndGet() == 1) {
                        throw new AlertLifecycleEvaluationInProgressException();
                    }
                    secondAttempt.countDown();
                    return null;
                },
                properties(1, 1));
        try {
            submit(scheduler, "checkout-burn");
            awaitPendingClearance(scheduler, "checkout-burn");

            submit(scheduler, "checkout-burn");

            assertThat(secondAttempt.await(5, TimeUnit.SECONDS)).isTrue();
            assertThat(calls).hasValue(2);
        } finally {
            scheduler.close();
        }
    }

    @Test
    void rejectsNewWorkWhileWorkersAreSaturatedAndAllowsRetryAfterCapacityReturns() throws Exception {
        CountDownLatch firstStarted = new CountDownLatch(1);
        CountDownLatch releaseFirst = new CountDownLatch(1);
        CountDownLatch firstFinished = new CountDownLatch(1);
        CountDownLatch secondStarted = new CountDownLatch(1);
        AtomicInteger calls = new AtomicInteger();
        AlertEvaluationScheduler scheduler = scheduler(
                catalog(policy("first-policy", true), policy("second-policy", true)),
                policyId -> {
                    calls.incrementAndGet();
                    if (policyId.equals("first-policy")) {
                        firstStarted.countDown();
                        try {
                            assertThat(releaseFirst.await(5, TimeUnit.SECONDS)).isTrue();
                        } catch (InterruptedException exception) {
                            Thread.currentThread().interrupt();
                        } finally {
                            firstFinished.countDown();
                        }
                    } else if (policyId.equals("second-policy")) {
                        secondStarted.countDown();
                    }
                    return null;
                },
                properties(1, 0));
        try {
            submit(scheduler, "first-policy");
            assertThat(firstStarted.await(5, TimeUnit.SECONDS)).isTrue();

            submit(scheduler, "second-policy");

            assertThat(secondStarted.await(200, TimeUnit.MILLISECONDS)).isFalse();
            releaseFirst.countDown();
            assertThat(firstFinished.await(5, TimeUnit.SECONDS)).isTrue();
            awaitIdle(scheduler);

            while (secondStarted.getCount() > 0) {
                submit(scheduler, "second-policy");
                if (!secondStarted.await(50, TimeUnit.MILLISECONDS) && secondStarted.getCount() > 0) {
                    Thread.yield();
                }
            }
            assertThat(calls).hasValue(2);
        } finally {
            releaseFirst.countDown();
            scheduler.close();
        }
    }

    @Test
    void closeIsIdempotentAndStopsFurtherSubmissions() throws Exception {
        CountDownLatch invoked = new CountDownLatch(1);
        AlertEvaluationScheduler scheduler = scheduler(
                catalog(policy("checkout-burn", true)),
                policyId -> {
                    invoked.countDown();
                    return null;
                },
                properties(1, 1));
        try {
            scheduler.close();
            scheduler.close();

            submit(scheduler, "checkout-burn");

            assertThat(invoked.await(200, TimeUnit.MILLISECONDS)).isFalse();
        } finally {
            scheduler.close();
        }
    }

    private static void submit(AlertEvaluationScheduler scheduler, String policyId) {
        try {
            SUBMIT.invoke(scheduler, policyId);
        } catch (IllegalAccessException exception) {
            throw new AssertionError("unable to access scheduler submission", exception);
        } catch (InvocationTargetException exception) {
            throw new AssertionError("scheduler submission failed", exception.getCause());
        }
    }

    @SuppressWarnings("unchecked")
    private static void awaitPendingClearance(AlertEvaluationScheduler scheduler, String policyId) throws Exception {
        var pendingField = AlertEvaluationScheduler.class.getDeclaredField("pending");
        pendingField.setAccessible(true);
        long deadlineNanos = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (System.nanoTime() < deadlineNanos) {
            if (!((Set<String>) pendingField.get(scheduler)).contains(policyId)) {
                return;
            }
            Thread.sleep(10);
        }
        throw new AssertionError("policy remained pending longer than expected");
    }

    private static void awaitIdle(AlertEvaluationScheduler scheduler) throws Exception {
        var workersField = AlertEvaluationScheduler.class.getDeclaredField("workers");
        workersField.setAccessible(true);
        ThreadPoolExecutor workers = (ThreadPoolExecutor) workersField.get(scheduler);
        long deadlineNanos = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (System.nanoTime() < deadlineNanos) {
            if (workers.getActiveCount() == 0 && workers.getQueue().isEmpty()) {
                return;
            }
            Thread.sleep(10);
        }
        throw new AssertionError("scheduler workers remained busy longer than expected");
    }

    private static Method submitMethod() {
        try {
            Method method = AlertEvaluationScheduler.class.getDeclaredMethod("submit", String.class);
            method.setAccessible(true);
            return method;
        } catch (NoSuchMethodException exception) {
            throw new ExceptionInInitializerError(exception);
        }
    }

    private static AlertEvaluationScheduler scheduler(
            AlertPolicyCatalog catalog,
            AlertLifecycleEvaluationUseCase evaluations,
            AlertSchedulingSettings properties) {
        return new AlertEvaluationScheduler(catalog, evaluations, properties);
    }

    private static AlertSchedulingSettings properties(int workerCount, int queueCapacity) {
        return new AlertSchedulingSettings(INTERVAL, workerCount, queueCapacity, SHUTDOWN_GRACE_PERIOD);
    }

    private static AlertPolicyCatalog catalog(AlertPolicy... policies) {
        List<AlertPolicy> allPolicies = List.of(policies);
        return new AlertPolicyCatalog() {
            @Override
            public List<AlertPolicy> findAll() {
                return allPolicies;
            }

            @Override
            public Optional<AlertPolicy> findById(String id) {
                return allPolicies.stream().filter(policy -> policy.id().equals(id)).findFirst();
            }
        };
    }

    private static AlertPolicy policy(String id, boolean enabled) {
        return new AlertPolicy(
                id,
                "Policy " + id,
                null,
                enabled,
                "checkout-availability",
                new AlertCondition(AlertConditionType.BURN_RATE_ABOVE, BigDecimal.ONE));
    }
}
