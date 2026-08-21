package io.geordi.slos.application;

public final class SloNotFoundException extends RuntimeException {

    public SloNotFoundException() {
        super("SLO not found");
    }
}
