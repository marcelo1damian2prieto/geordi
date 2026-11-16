package io.geordi.bootstrap.security.oidc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import io.geordi.bootstrap.security.SecurityFailure;
import java.net.URI;
import java.util.Collections;
import java.util.List;
import org.junit.jupiter.api.Test;

class OidcBrowserBindingTest {
    private static final String STATE = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFG";

    @Test
    void extractsStateAndEmitsHostOnlyShortLivedCookie() {
        assertThat(OidcBrowserBinding.stateFromAuthorizationUri(URI.create(
                "https://auth.example/authorize?tenant=geordi&state=" + STATE))).isEqualTo(STATE);
        assertThat(OidcBrowserBinding.cookie(STATE))
                .isEqualTo("__Host-Geordi-OIDC=" + STATE + "; Path=/; Max-Age=300; Secure; HttpOnly; SameSite=Lax");
    }

    @Test
    void acceptsOnlyOneMatchingBrowserCookieAndRejectsCrossBrowserCallback() {
        OidcBrowserBinding.requireCookie(Collections.enumeration(List.of("theme=dark; __Host-Geordi-OIDC=" + STATE)), STATE);
        assertThatThrownBy(() -> OidcBrowserBinding.requireCookie(
                Collections.enumeration(List.of("__Host-Geordi-OIDC=" + "A".repeat(43))), STATE))
                .isInstanceOf(SecurityFailure.class);
        assertThatThrownBy(() -> OidcBrowserBinding.requireCookie(Collections.enumeration(List.of(
                "__Host-Geordi-OIDC=" + STATE + "; __Host-Geordi-OIDC=" + STATE)), STATE))
                .isInstanceOf(SecurityFailure.class);
    }

    @Test
    void rejectsMissingOrDuplicatedAuthorizationState() {
        assertThatThrownBy(() -> OidcBrowserBinding.stateFromAuthorizationUri(URI.create(
                "https://auth.example/authorize?state=" + STATE + "&state=" + STATE)))
                .isInstanceOf(SecurityFailure.class);
        assertThatThrownBy(() -> OidcBrowserBinding.requireCookie(null, STATE))
                .isInstanceOf(SecurityFailure.class);
    }
}
