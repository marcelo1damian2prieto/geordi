package io.geordi.core.application.security;

/** Closed, data-free observation boundary. No caller identity or request string is accepted. */
public interface SecurityObservation {
    enum Mechanism { NONE, AMBIGUOUS, SESSION, BEARER }
    enum Result { SUCCESS, FAILURE, ALLOWED, DENIED }
    enum Reason { VALID, MISSING, INVALID, DEPENDENCY, AMBIGUOUS, CAPACITY, PERMISSION, CSRF, ORIGIN, ROUTE }
    enum Endpoint { READ, ACKNOWLEDGE, EVALUATE, ME, LOGIN, CALLBACK, CSRF, LOGOUT, PROBE, DENIED }

    void authentication(Mechanism mechanism, Result result, Reason reason, Endpoint endpoint);
    void authorization(Mechanism mechanism, Result result, Reason reason, Endpoint endpoint);
}
