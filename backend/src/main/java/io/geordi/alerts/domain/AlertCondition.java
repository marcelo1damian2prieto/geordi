package io.geordi.alerts.domain;

public sealed interface AlertCondition permits BurnRateAboveCondition, MultiwindowBurnRateCondition {

    AlertConditionType type();
}
