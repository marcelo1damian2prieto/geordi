package io.geordi.core.application.security;

public enum GeordiPermission {
    OBSERVABILITY_READ("observability:read"),
    ALERT_ACKNOWLEDGE("alerts:acknowledge"),
    ALERT_EVALUATE("alerts:evaluate");

    private final String publicName;

    GeordiPermission(String publicName) {
        this.publicName = publicName;
    }

    public String publicName() {
        return publicName;
    }
}
