package io.geordi.alerts.adapter.out.persistence;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.geordi.alerts.domain.AlertCondition;
import io.geordi.alerts.domain.AlertEvaluation;
import io.geordi.alerts.domain.AlertEvaluationStatus;
import io.geordi.alerts.domain.AlertEvidence;
import io.geordi.alerts.domain.AlertLifecycle;
import io.geordi.alerts.domain.AlertLifecycleState;
import io.geordi.alerts.domain.AlertObservationWindow;
import io.geordi.alerts.domain.AlertTransition;
import io.geordi.alerts.domain.AlertTransitionType;
import io.geordi.alerts.domain.AlertUnavailableReason;
import io.geordi.alerts.domain.BurnRateAboveCondition;
import io.geordi.alerts.domain.BurnRateBand;
import io.geordi.alerts.domain.BurnRateBandOutcome;
import io.geordi.alerts.domain.BurnRateBandResult;
import io.geordi.alerts.domain.BurnRateEvidence;
import io.geordi.alerts.domain.EvaluationWindow;
import io.geordi.alerts.domain.MultiwindowBurnRateCondition;
import io.geordi.alerts.domain.MultiwindowBurnRateEvidence;
import io.geordi.alerts.domain.ServiceIdentity;
import io.geordi.alerts.domain.TimeRange;
import io.geordi.alerts.domain.WindowBurnRateObservation;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Objects;
import java.util.Set;

/** Explicit adapter-owned codec for the durable M17 v1 and M18 v2 JSON contracts. */
final class AlertPersistenceJsonCodec {

    private static final int V2 = 2;
    private static final String VERSION = "persistenceFormatVersion";
    private static final String LIFECYCLE = "lifecycle";
    private static final String TRANSITION = "transition";

    private final ObjectMapper mapper;

    AlertPersistenceJsonCodec(ObjectMapper mapper) {
        Objects.requireNonNull(mapper, "object mapper must not be null");
        this.mapper = mapper.copy();
        this.mapper.enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION.mappedFeature());
        this.mapper.enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);
        this.mapper.enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS);
    }

    String writeLifecycle(AlertLifecycle lifecycle) {
        Objects.requireNonNull(lifecycle, "alert lifecycle must not be null");
        boolean legacy = lifecycle.condition() instanceof BurnRateAboveCondition;
        ObjectNode value = writeLifecycleValue(lifecycle, legacy);
        return json(legacy ? value : envelope(LIFECYCLE, value));
    }

    AlertLifecycle readLifecycle(String json) {
        JsonNode root = tree(json);
        if (!root.has(VERSION)) {
            return readLifecycleValue(root, true);
        }
        return readLifecycleValue(v2Envelope(root, LIFECYCLE), false);
    }

    String writeTransition(AlertTransition transition) {
        Objects.requireNonNull(transition, "alert transition must not be null");
        boolean legacy = transition.evaluation().condition() instanceof BurnRateAboveCondition;
        ObjectNode value = writeTransitionValue(transition, legacy);
        return json(legacy ? value : envelope(TRANSITION, value));
    }

    AlertTransition readTransition(String json) {
        JsonNode root = tree(json);
        if (!root.has(VERSION)) {
            return readTransitionValue(root, true);
        }
        return readTransitionValue(v2Envelope(root, TRANSITION), false);
    }

    private ObjectNode envelope(String member, ObjectNode value) {
        ObjectNode root = mapper.createObjectNode();
        root.put(VERSION, V2);
        root.set(member, value);
        return root;
    }

    private JsonNode v2Envelope(JsonNode root, String member) {
        requireObject(root, VERSION, member);
        JsonNode version = root.get(VERSION);
        if (!version.isIntegralNumber() || !version.canConvertToInt() || version.intValue() != V2) {
            throw invalid();
        }
        return root.get(member);
    }

    private ObjectNode writeLifecycleValue(AlertLifecycle value, boolean legacy) {
        requireFormat(value.condition(), legacy);
        ObjectNode node = mapper.createObjectNode();
        node.put("policyId", value.policyId());
        node.put("sloId", value.sloId());
        node.set("condition", writeCondition(value.condition(), legacy));
        setNullable(node, "boundService", value.boundService() == null ? null : writeService(value.boundService()));
        putNullable(node, "boundWindow", value.boundWindow() == null ? null : value.boundWindow().name());
        node.put("state", value.state().name());
        node.set("latestEvaluation", writeEvaluation(value.latestEvaluation(), legacy));
        setNullable(node, "activeEvidence", value.activeEvidence() == null
                ? null : writeEvidence(value.activeEvidence(), legacy));
        putInstant(node, "startedAt", value.startedAt());
        putInstant(node, "resolvedAt", value.resolvedAt());
        putInstant(node, "lastStateChangeAt", value.lastStateChangeAt());
        putInstant(node, "lastProcessedAt", value.lastProcessedAt());
        putInstant(node, "lastEvidenceAt", value.lastEvidenceAt());
        setNullable(node, "latestTransition", value.latestTransition() == null
                ? null : writeTransitionValue(value.latestTransition(), legacy));
        return node;
    }

    private AlertLifecycle readLifecycleValue(JsonNode node, boolean legacy) {
        requireObject(node,
                "policyId", "sloId", "condition", "boundService", "boundWindow", "state",
                "latestEvaluation", "activeEvidence", "startedAt", "resolvedAt", "lastStateChangeAt",
                "lastProcessedAt", "lastEvidenceAt", "latestTransition");
        try {
            AlertCondition condition = readCondition(node.get("condition"), legacy);
            ServiceIdentity boundService = nullable(node.get("boundService"))
                    ? null : readService(node.get("boundService"));
            EvaluationWindow boundWindow = nullable(node.get("boundWindow"))
                    ? null : enumValue(EvaluationWindow.class, text(node.get("boundWindow")));
            AlertEvaluation latest = readEvaluation(node.get("latestEvaluation"), legacy);
            AlertEvidence active = nullable(node.get("activeEvidence"))
                    ? null : readEvidence(node.get("activeEvidence"), legacy, condition);
            AlertTransition transition = nullable(node.get("latestTransition"))
                    ? null : readTransitionValue(node.get("latestTransition"), legacy);
            return new AlertLifecycle(
                    text(node.get("policyId")), text(node.get("sloId")), condition, boundService, boundWindow,
                    enumValue(AlertLifecycleState.class, text(node.get("state"))), latest, active,
                    instant(node.get("startedAt"), true), instant(node.get("resolvedAt"), true),
                    instant(node.get("lastStateChangeAt"), true), instant(node.get("lastProcessedAt"), false),
                    instant(node.get("lastEvidenceAt"), true), transition);
        } catch (InvalidPersistenceJsonException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            throw invalid();
        }
    }

    private ObjectNode writeTransitionValue(AlertTransition value, boolean legacy) {
        requireFormat(value.evaluation().condition(), legacy);
        ObjectNode node = mapper.createObjectNode();
        node.put("policyId", value.policyId());
        node.put("type", value.type().name());
        node.put("previousState", value.previousState().name());
        node.put("currentState", value.currentState().name());
        putInstant(node, "occurredAt", value.occurredAt());
        node.set("evaluation", writeEvaluation(value.evaluation(), legacy));
        return node;
    }

    private AlertTransition readTransitionValue(JsonNode node, boolean legacy) {
        requireObject(node, "policyId", "type", "previousState", "currentState", "occurredAt",
                "evaluation");
        try {
            return new AlertTransition(
                    text(node.get("policyId")), enumValue(AlertTransitionType.class, text(node.get("type"))),
                    enumValue(AlertLifecycleState.class, text(node.get("previousState"))),
                    enumValue(AlertLifecycleState.class, text(node.get("currentState"))),
                    instant(node.get("occurredAt"), false), readEvaluation(node.get("evaluation"), legacy));
        } catch (InvalidPersistenceJsonException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            throw invalid();
        }
    }

    private ObjectNode writeEvaluation(AlertEvaluation value, boolean legacy) {
        requireFormat(value.condition(), legacy);
        if (legacy && value.evidence() != null && !(value.evidence() instanceof BurnRateEvidence)
                || !legacy && value.evidence() != null && !(value.evidence() instanceof MultiwindowBurnRateEvidence)) {
            throw invalid();
        }
        ObjectNode node = mapper.createObjectNode();
        node.put("policyId", value.policyId());
        node.put("policyName", value.policyName());
        node.put("sloId", value.sloId());
        node.set("condition", writeCondition(value.condition(), legacy));
        node.put("status", value.status().name());
        putNullable(node, "reason", value.reason() == null ? null : value.reason().name());
        setNullable(node, "evidence", value.evidence() == null ? null : writeEvidence(value.evidence(), legacy));
        if (!legacy) {
            ArrayNode results = node.putArray("bandResults");
            value.bandResults().forEach(result -> results.add(writeBandResult(result)));
        }
        return node;
    }

    private AlertEvaluation readEvaluation(JsonNode node, boolean legacy) {
        if (legacy) {
            requireObject(node, "policyId", "policyName", "sloId", "condition", "status",
                    "reason", "evidence");
        } else {
            requireObject(node, "policyId", "policyName", "sloId", "condition", "status",
                    "reason", "evidence", "bandResults");
        }
        try {
            AlertCondition condition = readCondition(node.get("condition"), legacy);
            AlertEvidence evidence = nullable(node.get("evidence"))
                    ? null : readEvidence(node.get("evidence"), legacy, condition);
            AlertEvaluation evaluation = new AlertEvaluation(
                    text(node.get("policyId")), text(node.get("policyName")), text(node.get("sloId")), condition,
                    enumValue(AlertEvaluationStatus.class, text(node.get("status"))),
                    nullable(node.get("reason")) ? null
                            : enumValue(AlertUnavailableReason.class, text(node.get("reason"))),
                    evidence);
            if (!legacy) {
                List<StoredBandResult> stored = readBandResults(node.get("bandResults"));
                List<StoredBandResult> derived = evaluation.bandResults().stream()
                        .map(result -> new StoredBandResult(result.band(), result.outcome())).toList();
                if (!stored.equals(derived)) {
                    throw invalid();
                }
            }
            return evaluation;
        } catch (InvalidPersistenceJsonException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            throw invalid();
        }
    }

    private ObjectNode writeCondition(AlertCondition condition, boolean legacy) {
        requireFormat(condition, legacy);
        ObjectNode node = mapper.createObjectNode();
        node.put("type", condition.type().name());
        if (condition instanceof BurnRateAboveCondition scalar) {
            node.put("threshold", scalar.threshold());
        } else if (condition instanceof MultiwindowBurnRateCondition multiwindow) {
            ArrayNode bands = node.putArray("bands");
            multiwindow.bands().forEach(band -> bands.add(writeBand(band)));
        }
        return node;
    }

    private AlertCondition readCondition(JsonNode node, boolean legacy) {
        try {
            if (legacy) {
                requireObject(node, "type", "threshold");
                if (!"BURN_RATE_ABOVE".equals(text(node.get("type")))) {
                    throw invalid();
                }
                return new BurnRateAboveCondition(decimal(node.get("threshold")));
            }
            requireObject(node, "type", "bands");
            if (!"MULTIWINDOW_BURN_RATE".equals(text(node.get("type")))) {
                throw invalid();
            }
            List<BurnRateBand> bands = readArray(node.get("bands"), this::readBand);
            MultiwindowBurnRateCondition condition = new MultiwindowBurnRateCondition(bands);
            if (!bands.equals(condition.bands())) {
                throw invalid();
            }
            return condition;
        } catch (InvalidPersistenceJsonException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            throw invalid();
        }
    }

    private ObjectNode writeBand(BurnRateBand value) {
        ObjectNode node = mapper.createObjectNode();
        node.put("longWindow", value.longWindow().name());
        node.put("shortWindow", value.shortWindow().name());
        node.put("threshold", value.threshold());
        return node;
    }

    private BurnRateBand readBand(JsonNode node) {
        requireObject(node, "longWindow", "shortWindow", "threshold");
        return new BurnRateBand(
                enumValue(AlertObservationWindow.class, text(node.get("longWindow"))),
                enumValue(AlertObservationWindow.class, text(node.get("shortWindow"))),
                decimal(node.get("threshold")));
    }

    private ObjectNode writeEvidence(AlertEvidence evidence, boolean legacy) {
        if (legacy && evidence instanceof BurnRateEvidence scalar) {
            ObjectNode node = mapper.createObjectNode();
            node.put("sloId", scalar.sloId());
            node.set("service", writeService(scalar.service()));
            node.put("window", scalar.window().name());
            node.set("range", writeRange(scalar.range()));
            putInstant(node, "evaluatedAt", scalar.evaluatedAt());
            putDecimal(node, "observedBurnRate", scalar.observedBurnRate());
            putNullable(node, "reason", scalar.reason() == null ? null : scalar.reason().name());
            return node;
        }
        if (!legacy && evidence instanceof MultiwindowBurnRateEvidence aggregate) {
            ObjectNode node = mapper.createObjectNode();
            node.put("sloId", aggregate.sloId());
            node.set("service", writeService(aggregate.service()));
            node.put("configuredSloWindow", aggregate.configuredSloWindow().name());
            putInstant(node, "evaluatedAt", aggregate.evaluatedAt());
            ArrayNode observations = node.putArray("observations");
            aggregate.observations().forEach(value -> observations.add(writeObservation(value)));
            return node;
        }
        throw invalid();
    }

    private AlertEvidence readEvidence(JsonNode node, boolean legacy, AlertCondition condition) {
        try {
            if (legacy) {
                requireObject(node, "sloId", "service", "window", "range", "evaluatedAt",
                        "observedBurnRate", "reason");
                return new BurnRateEvidence(
                        text(node.get("sloId")), readService(node.get("service")),
                        enumValue(EvaluationWindow.class, text(node.get("window"))), readRange(node.get("range")),
                        instant(node.get("evaluatedAt"), false), decimal(node.get("observedBurnRate"), true),
                        nullable(node.get("reason")) ? null
                                : enumValue(AlertUnavailableReason.class, text(node.get("reason"))));
            }
            if (!(condition instanceof MultiwindowBurnRateCondition multiwindow)) {
                throw invalid();
            }
            requireObject(node, "sloId", "service", "configuredSloWindow", "evaluatedAt",
                    "observations");
            List<WindowBurnRateObservation> observations = readArray(
                    node.get("observations"), this::readObservation);
            MultiwindowBurnRateEvidence evidence = MultiwindowBurnRateEvidence.of(
                    text(node.get("sloId")), readService(node.get("service")),
                    enumValue(EvaluationWindow.class, text(node.get("configuredSloWindow"))),
                    instant(node.get("evaluatedAt"), false), multiwindow.observationWindows(), observations);
            if (!observations.equals(evidence.observations())) {
                throw invalid();
            }
            return evidence;
        } catch (InvalidPersistenceJsonException exception) {
            throw exception;
        } catch (RuntimeException exception) {
            throw invalid();
        }
    }

    private ObjectNode writeObservation(WindowBurnRateObservation value) {
        ObjectNode node = mapper.createObjectNode();
        node.put("observationWindow", value.observationWindow().name());
        node.set("range", writeRange(value.range()));
        putDecimal(node, "observedBurnRate", value.observedBurnRate());
        putNullable(node, "reason", value.reason() == null ? null : value.reason().name());
        return node;
    }

    private WindowBurnRateObservation readObservation(JsonNode node) {
        requireObject(node, "observationWindow", "range", "observedBurnRate", "reason");
        return new WindowBurnRateObservation(
                enumValue(AlertObservationWindow.class, text(node.get("observationWindow"))),
                readRange(node.get("range")), decimal(node.get("observedBurnRate"), true),
                nullable(node.get("reason")) ? null
                        : enumValue(AlertUnavailableReason.class, text(node.get("reason"))));
    }

    private ObjectNode writeBandResult(BurnRateBandResult value) {
        ObjectNode node = mapper.createObjectNode();
        node.set("band", writeBand(value.band()));
        node.put("outcome", value.outcome().name());
        return node;
    }

    private List<StoredBandResult> readBandResults(JsonNode node) {
        return readArray(node, value -> {
            requireObject(value, "band", "outcome");
            return new StoredBandResult(
                    readBand(value.get("band")),
                    enumValue(BurnRateBandOutcome.class, text(value.get("outcome"))));
        });
    }

    private ObjectNode writeService(ServiceIdentity value) {
        ObjectNode node = mapper.createObjectNode();
        node.put("name", value.name());
        node.put("namespace", value.namespace());
        node.put("environment", value.environment());
        return node;
    }

    private ServiceIdentity readService(JsonNode node) {
        requireObject(node, "name", "namespace", "environment");
        return new ServiceIdentity(
                text(node.get("name")), nullable(node.get("namespace")) ? null : text(node.get("namespace")),
                text(node.get("environment")));
    }

    private ObjectNode writeRange(TimeRange value) {
        ObjectNode node = mapper.createObjectNode();
        putInstant(node, "from", value.from());
        putInstant(node, "to", value.to());
        return node;
    }

    private TimeRange readRange(JsonNode node) {
        requireObject(node, "from", "to");
        return new TimeRange(instant(node.get("from"), false), instant(node.get("to"), false));
    }

    private JsonNode tree(String json) {
        if (json == null || json.isBlank()) {
            throw invalid();
        }
        try {
            JsonNode root = mapper.readTree(json);
            if (root == null || !root.isObject()) {
                throw invalid();
            }
            return root;
        } catch (JsonProcessingException exception) {
            throw invalid();
        }
    }

    private String json(ObjectNode node) {
        try {
            return mapper.writeValueAsString(node);
        } catch (JsonProcessingException exception) {
            throw invalid();
        }
    }

    private static void requireFormat(AlertCondition condition, boolean legacy) {
        if (legacy != (condition instanceof BurnRateAboveCondition)) {
            throw invalid();
        }
    }

    private static void requireObject(JsonNode node, String... fields) {
        if (node == null || !node.isObject()) {
            throw invalid();
        }
        Set<String> expected = new HashSet<>(Arrays.asList(fields));
        Set<String> actual = new HashSet<>();
        node.fieldNames().forEachRemaining(actual::add);
        if (!actual.equals(expected)) {
            throw invalid();
        }
    }

    private static String text(JsonNode node) {
        if (node == null || !node.isTextual()) {
            throw invalid();
        }
        return node.textValue();
    }

    private static BigDecimal decimal(JsonNode node) {
        return decimal(node, false);
    }

    private static BigDecimal decimal(JsonNode node, boolean nullable) {
        if (nullable && nullable(node)) {
            return null;
        }
        if (node == null || !node.isNumber()) {
            throw invalid();
        }
        return node.decimalValue();
    }

    private static Instant instant(JsonNode node, boolean nullable) {
        if (nullable && nullable(node)) {
            return null;
        }
        BigDecimal epoch = decimal(node);
        try {
            BigDecimal secondsValue = epoch.setScale(0, RoundingMode.FLOOR);
            long seconds = secondsValue.longValueExact();
            int nanos = epoch.subtract(secondsValue).movePointRight(9).intValueExact();
            return Instant.ofEpochSecond(seconds, nanos);
        } catch (ArithmeticException exception) {
            throw invalid();
        }
    }

    private static <E extends Enum<E>> E enumValue(Class<E> type, String value) {
        try {
            return Enum.valueOf(type, value);
        } catch (IllegalArgumentException exception) {
            throw invalid();
        }
    }

    private static boolean nullable(JsonNode node) {
        return node == null || node.isNull();
    }

    private static <T> List<T> readArray(JsonNode node, NodeReader<T> reader) {
        if (node == null || !node.isArray()) {
            throw invalid();
        }
        List<T> values = new ArrayList<>();
        node.forEach(value -> values.add(reader.read(value)));
        return List.copyOf(values);
    }

    private static void setNullable(ObjectNode node, String field, JsonNode value) {
        if (value == null) {
            node.putNull(field);
        } else {
            node.set(field, value);
        }
    }

    private static void putNullable(ObjectNode node, String field, String value) {
        if (value == null) {
            node.putNull(field);
        } else {
            node.put(field, value);
        }
    }

    private static void putDecimal(ObjectNode node, String field, BigDecimal value) {
        if (value == null) {
            node.putNull(field);
        } else {
            node.put(field, value);
        }
    }

    private static void putInstant(ObjectNode node, String field, Instant value) {
        if (value == null) {
            node.putNull(field);
            return;
        }
        BigDecimal epoch = BigDecimal.valueOf(value.getEpochSecond())
                .add(BigDecimal.valueOf(value.getNano(), 9));
        node.put(field, epoch);
    }

    private static InvalidPersistenceJsonException invalid() {
        return new InvalidPersistenceJsonException();
    }

    private record StoredBandResult(BurnRateBand band, BurnRateBandOutcome outcome) { }

    @FunctionalInterface
    private interface NodeReader<T> {
        T read(JsonNode node);
    }

    static final class InvalidPersistenceJsonException extends RuntimeException {
        private InvalidPersistenceJsonException() {
            super("invalid durable alert JSON");
        }
    }
}
