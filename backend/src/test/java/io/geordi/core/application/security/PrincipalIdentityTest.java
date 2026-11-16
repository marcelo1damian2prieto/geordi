package io.geordi.core.application.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

class PrincipalIdentityTest {
    @ParameterizedTest
    @ValueSource(strings = {"http://idp.example", "https://user@idp.example", "https://idp.example?x", "https://idp.example#x", "https://é.example", "relative", "https:///missing"})
    void rejectsInvalidIssuer(String issuer) {
        assertThatThrownBy(() -> new PrincipalIdentity(issuer, "subject")).isInstanceOf(IllegalArgumentException.class);
    }

    @ParameterizedTest
    @ValueSource(strings = {"", " ", "\t", "\n", "é", "\u007f"})
    void rejectsInvalidSubject(String subject) {
        assertThatThrownBy(() -> new PrincipalIdentity("https://idp.example", subject)).isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void malformedUriDoesNotEscapeThroughExceptionTextOrCause() {
        assertThatThrownBy(() -> new PrincipalIdentity("https://idp.example/%identity-sentinel", "subject"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessage("invalid identity issuer").hasNoCause();
    }

    @Test
    void identityIsExactAndBounded() {
        var identity = new PrincipalIdentity("https://idp.example", " Subject ");
        assertThat(identity.subject()).isEqualTo(" Subject ");
        assertThat(identity).isNotEqualTo(new PrincipalIdentity("https://idp.example/", " Subject "));
        assertThat(identity).isNotEqualTo(new PrincipalIdentity("https://idp.example", "Subject"));
        assertThatThrownBy(() -> new PrincipalIdentity("https://idp.example", "x".repeat(256)))
                .isInstanceOf(IllegalArgumentException.class);
        String prefix = "https://idp.example/";
        assertThat(new PrincipalIdentity(prefix + "x".repeat(2048 - prefix.length()), "x".repeat(255))).isNotNull();
        assertThatThrownBy(() -> new PrincipalIdentity(prefix + "x".repeat(2049 - prefix.length()), "s"))
                .isInstanceOf(IllegalArgumentException.class);
    }
}
