package io.geordi.alerts.adapter.in.worker;

import io.geordi.alerts.application.AlertLifecycleEvaluationInProgressException;
import io.geordi.alerts.application.AlertLifecycleEvaluationUseCase;
import io.geordi.alerts.application.AlertSchedulingSettings;
import io.geordi.alerts.application.port.out.AlertPolicyCatalog;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.SynchronousQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.metrics.DoubleHistogram;
import io.opentelemetry.api.metrics.LongCounter;

public final class AlertEvaluationScheduler implements AutoCloseable {
    private static final System.Logger LOGGER = System.getLogger(AlertEvaluationScheduler.class.getName());
    private final AlertPolicyCatalog catalog;
    private final AlertLifecycleEvaluationUseCase evaluations;
    private final AlertSchedulingSettings settings;
    private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor();
    private final ThreadPoolExecutor workers;
    private final Set<String> pending = java.util.concurrent.ConcurrentHashMap.newKeySet();
    private final List<ScheduledFuture<?>> schedules = new ArrayList<>();
    private final AtomicBoolean accepting = new AtomicBoolean(true);
    private final LongCounter attempts;
    private final LongCounter completed;
    private final LongCounter failures;
    private final LongCounter overlapSkips;
    private final LongCounter rejections;
    private final DoubleHistogram duration;

    public AlertEvaluationScheduler(AlertPolicyCatalog catalog, AlertLifecycleEvaluationUseCase evaluations,
            AlertSchedulingSettings settings) {
        this.catalog = catalog;
        this.evaluations = evaluations;
        this.settings = settings;
        workers = new ThreadPoolExecutor(settings.workerCount(), settings.workerCount(), 0L, TimeUnit.MILLISECONDS,
                settings.queueCapacity() == 0 ? new SynchronousQueue<>() : new ArrayBlockingQueue<>(settings.queueCapacity()), new ThreadPoolExecutor.AbortPolicy());
        var meter = GlobalOpenTelemetry.getMeter("io.geordi.alerts");
        attempts = meter.counterBuilder("geordi.alert.scheduler.attempts").build();
        completed = meter.counterBuilder("geordi.alert.scheduler.completed").build();
        failures = meter.counterBuilder("geordi.alert.scheduler.failures").build();
        overlapSkips = meter.counterBuilder("geordi.alert.scheduler.overlap_skips").build();
        rejections = meter.counterBuilder("geordi.alert.scheduler.rejections").build();
        duration = meter.histogramBuilder("geordi.alert.scheduler.duration").setUnit("s").build();
    }

    public void start() {
        List<String> ids = catalog.findAll().stream().filter(policy -> policy.enabled()).map(policy -> policy.id()).toList();
        for (int index = 0; index < ids.size(); index++) {
            long initialDelay = settings.interval().toMillis() * index / ids.size();
            String policyId = ids.get(index);
            schedules.add(timer.scheduleAtFixedRate(() -> submit(policyId), initialDelay,
                    settings.interval().toMillis(), TimeUnit.MILLISECONDS));
        }
    }

    private void submit(String policyId) {
        if (!accepting.get()) return;
        if (!pending.add(policyId)) { overlapSkips.add(1); return; }
        try { workers.execute(() -> evaluate(policyId)); }
        catch (RejectedExecutionException exception) { pending.remove(policyId); rejections.add(1); }
    }

    private void evaluate(String policyId) {
        attempts.add(1); long started = System.nanoTime();
        try { evaluations.evaluate(policyId); completed.add(1); }
        catch (AlertLifecycleEvaluationInProgressException exception) { overlapSkips.add(1); }
        catch (RuntimeException exception) { failures.add(1); LOGGER.log(System.Logger.Level.ERROR, "scheduled alert lifecycle evaluation failed"); }
        finally { pending.remove(policyId); duration.record((System.nanoTime() - started) / 1_000_000_000.0); }
    }

    @Override public void close() {
        if (!accepting.compareAndSet(true, false)) return;
        schedules.forEach(schedule -> schedule.cancel(false)); timer.shutdown(); workers.shutdown();
        try { if (!workers.awaitTermination(settings.shutdownGracePeriod().toMillis(), TimeUnit.MILLISECONDS)) workers.shutdownNow(); }
        catch (InterruptedException exception) { Thread.currentThread().interrupt(); workers.shutdownNow(); }
    }
}
