package io.geordi.core.application.security;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.HashSet;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

class AuthenticatedPrincipalTest {
    private static final PrincipalIdentity ID = new PrincipalIdentity("https://idp.example", "subject");

    @ParameterizedTest
    @EnumSource(value = GeordiPermission.class, names = {"ALERT_ACKNOWLEDGE", "ALERT_EVALUATE"})
    void permissionsAreImmutableAndNeverImplyRead(GeordiPermission mutationPermission) {
        var permissions = new HashSet<>(Set.of(mutationPermission));
        var principal = new AuthenticatedPrincipal(ID, "Operator", permissions, AuthenticationMechanism.BEARER);
        permissions.add(GeordiPermission.OBSERVABILITY_READ);
        assertThat(principal.permissions()).containsExactly(mutationPermission);
        assertThatThrownBy(() -> principal.permissions().clear()).isInstanceOf(UnsupportedOperationException.class);
        assertThatThrownBy(() -> PermissionCheck.require(principal, GeordiPermission.OBSERVABILITY_READ))
                .isInstanceOf(PermissionDeniedException.class);
        PermissionCheck.require(principal, mutationPermission);
        assertThatThrownBy(() -> PermissionCheck.require(null, mutationPermission))
                .isInstanceOf(PermissionDeniedException.class);
    }

    @Test
    void optionalNameIsScalarBoundedWithoutNormalization() {
        for (String invalid : new String[] {"", "a\n", "a\u007f", "\ud800", "x".repeat(129), "😀".repeat(129)}) {
            assertThat(principal(invalid).displayName()).isNull();
        }
        assertThat(principal(null).displayName()).isNull();
        assertThat(principal(" Name ").displayName()).isEqualTo(" Name ");
        assertThat(principal("😀".repeat(128)).displayName()).isEqualTo("😀".repeat(128));
    }

    @Test
    void permissionVocabularyIsExactlyTheFrozenContract() {
        assertThat(GeordiPermission.values()).extracting(GeordiPermission::publicName)
                .containsExactlyInAnyOrder("observability:read", "alerts:acknowledge", "alerts:evaluate");
    }

    private static AuthenticatedPrincipal principal(String name) {
        return new AuthenticatedPrincipal(ID, name, Set.of(), AuthenticationMechanism.SESSION);
    }
}
