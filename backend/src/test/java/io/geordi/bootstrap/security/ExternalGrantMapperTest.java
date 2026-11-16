package io.geordi.bootstrap.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.core.application.security.GeordiPermission;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;

class ExternalGrantMapperTest {
    private final ExternalGrantMapper mapper = new ExternalGrantMapper(Map.of(
            "viewer", Set.of(GeordiPermission.OBSERVABILITY_READ),
            "acknowledger", Set.of(GeordiPermission.ALERT_ACKNOWLEDGE),
            "evaluator", Set.of(GeordiPermission.ALERT_EVALUATE)));

    @Test
    void mapsOnlyConfiguredValuesWithoutImpliedGrants() {
        assertThat(mapper.map(false, null)).isEmpty();
        assertThat(mapper.map(true, List.of("unknown"))).isEmpty();
        assertThat(mapper.map(true, List.of("acknowledger"))).containsExactly(GeordiPermission.ALERT_ACKNOWLEDGE);
        assertThat(mapper.map(true, List.of("evaluator"))).containsExactly(GeordiPermission.ALERT_EVALUATE);
        assertThat(mapper.map(true, List.of("viewer", "evaluator", "evaluator")))
                .containsExactlyInAnyOrder(GeordiPermission.OBSERVABILITY_READ, GeordiPermission.ALERT_EVALUATE);
    }

    @Test
    void rejectsNullWrongShapeAndBoundViolationsRatherThanDroppingThem() {
        for (Object invalid : List.of("viewer", Map.of("viewer", true), List.of(1), List.of("x".repeat(129)),
                List.of("\ud800"), java.util.Collections.nCopies(101, "viewer"))) {
            assertThatThrownBy(() -> mapper.map(true, invalid)).isInstanceOf(SecurityFailure.class);
        }
        assertThatThrownBy(() -> mapper.map(true, null)).isInstanceOf(SecurityFailure.class);
        var withNull = new ArrayList<Object>();
        withNull.add(null);
        assertThatThrownBy(() -> mapper.map(true, withNull)).isInstanceOf(SecurityFailure.class);
        assertThat(mapper.map(true, List.of("😀".repeat(128)))).isEmpty();
    }
}
