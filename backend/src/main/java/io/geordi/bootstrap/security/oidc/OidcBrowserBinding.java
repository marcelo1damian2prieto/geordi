package io.geordi.bootstrap.security.oidc;

import io.geordi.bootstrap.security.SecurityFailure;
import java.net.URI;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Enumeration;

/** Binds an OIDC callback to the browser that initiated the authorization request. */
public final class OidcBrowserBinding {
    private static final String COOKIE_NAME = "__Host-Geordi-OIDC";

    private OidcBrowserBinding() { }

    public static String stateFromAuthorizationUri(URI authorizationUri) {
        String state = null;
        String rawQuery = authorizationUri.getRawQuery();
        if (rawQuery == null) throw SecurityFailure.invalid();
        for (String pair : rawQuery.split("&", -1)) {
            String[] parts = pair.split("=", 2);
            if (URLDecoder.decode(parts[0], StandardCharsets.UTF_8).equals("state")) {
                if (state != null || parts.length != 2) throw SecurityFailure.invalid();
                state = URLDecoder.decode(parts[1], StandardCharsets.UTF_8);
            }
        }
        if (state == null || !state.matches("[A-Za-z0-9_-]{43}")) throw SecurityFailure.invalid();
        return state;
    }

    public static String cookie(String state) {
        return COOKIE_NAME + "=" + state + "; Path=/; Max-Age=300; Secure; HttpOnly; SameSite=Lax";
    }

    public static String clearCookie() {
        return COOKIE_NAME + "=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax";
    }

    public static void requireCookie(Enumeration<String> cookieHeaders, String state) {
        if (state == null || !state.matches("[A-Za-z0-9_-]{43}")) throw SecurityFailure.invalid();
        String browserState = null;
        while (cookieHeaders != null && cookieHeaders.hasMoreElements()) {
            String header = cookieHeaders.nextElement();
            for (String item : header.split(";", -1)) {
                String[] parts = item.trim().split("=", 2);
                if (parts[0].equals(COOKIE_NAME)) {
                    if (browserState != null || parts.length != 2) throw SecurityFailure.invalid();
                    browserState = parts[1];
                }
            }
        }
        if (browserState == null || !MessageDigest.isEqual(
                state.getBytes(StandardCharsets.US_ASCII), browserState.getBytes(StandardCharsets.US_ASCII))) {
            throw SecurityFailure.invalid();
        }
    }
}
