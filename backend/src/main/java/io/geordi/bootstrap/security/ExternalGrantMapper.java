package io.geordi.bootstrap.security;

import io.geordi.core.application.security.GeordiPermission;
import java.util.EnumSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

public final class ExternalGrantMapper {
    private final Map<String, Set<GeordiPermission>> mapping;

    public ExternalGrantMapper(Map<String, Set<GeordiPermission>> mapping) {
        var copied = new LinkedHashMap<String, Set<GeordiPermission>>();
        mapping.forEach((key, permissions) -> copied.put(key, Set.copyOf(permissions)));
        this.mapping = Map.copyOf(copied);
    }

    public Set<GeordiPermission> map(boolean present, Object claim) {
        if (!present) return Set.of();
        if (!(claim instanceof List<?> values) || values.size() > 100) throw SecurityFailure.invalid();
        var permissions = EnumSet.noneOf(GeordiPermission.class);
        for (Object value : values) {
            if (!(value instanceof String grant) || !scalarBounded(grant, 128)) throw SecurityFailure.invalid();
            permissions.addAll(mapping.getOrDefault(grant, Set.of()));
        }
        return Set.copyOf(permissions);
    }

    static boolean scalarBounded(String value, int maximum) {
        return value != null && value.codePointCount(0, value.length()) <= maximum
                && value.codePoints().noneMatch(point -> point >= Character.MIN_SURROGATE && point <= Character.MAX_SURROGATE);
    }
}
