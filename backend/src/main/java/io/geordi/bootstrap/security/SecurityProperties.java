package io.geordi.bootstrap.security;

import io.geordi.core.application.security.GeordiPermission;
import io.geordi.core.application.security.PrincipalIdentity;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;
import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "geordi.security", ignoreUnknownFields = false)
public record SecurityProperties(String issuer, String apiAudience, String browserClientId,
        Path browserClientSecretFile, String publicBaseUrl, String grantClaim,
        Map<String, List<String>> grantMapping) {
    public SecurityProperties {
        new PrincipalIdentity(issuer, "configuration");
        new PublicOrigin(publicBaseUrl);
        requirePrintable(apiAudience, 255);
        requirePrintable(browserClientId, 255);
        requirePrintable(grantClaim, 128);
        if (apiAudience.equals(browserClientId)) throw new IllegalArgumentException("API and browser audiences must differ");
        if (browserClientSecretFile == null) throw new IllegalArgumentException("client secret file is required");
        if (grantMapping == null) throw new IllegalArgumentException("explicit permission mapping is required");
        readSecret(browserClientSecretFile);
        var copied = new LinkedHashMap<String, List<String>>();
        grantMapping.forEach((key, permissions) -> {
            if (key == null || key.isEmpty() || !ExternalGrantMapper.scalarBounded(key, 128) || permissions == null) {
                throw new IllegalArgumentException("invalid permission mapping");
            }
            permissions.forEach(SecurityProperties::permission);
            copied.put(key, List.copyOf(permissions));
        });
        grantMapping = Map.copyOf(copied);
    }

    public Map<String, Set<GeordiPermission>> permissions() {
        var result = new LinkedHashMap<String, Set<GeordiPermission>>();
        grantMapping.forEach((key, values) -> result.put(key,
                values.stream().map(SecurityProperties::permission).collect(Collectors.toUnmodifiableSet())));
        return Map.copyOf(result);
    }

    public String clientSecret() {
        return readSecret(browserClientSecretFile);
    }

    private static String readSecret(Path file) {
        try (var stream = Files.newInputStream(file)) {
            byte[] bytes = stream.readNBytes(4097);
            try {
                if (bytes.length == 0 || bytes.length > 4096) throw new IllegalArgumentException("invalid client secret input");
                String secret = new String(bytes, StandardCharsets.UTF_8);
                requirePrintable(secret, 4096);
                return secret;
            } finally {
                Arrays.fill(bytes, (byte) 0);
            }
        } catch (IOException exception) {
            throw new IllegalArgumentException("client secret input unavailable");
        }
    }

    private static void requirePrintable(String value, int maximum) {
        if (value == null || value.isBlank() || value.length() > maximum
                || !value.chars().allMatch(character -> character >= 32 && character <= 126)) {
            throw new IllegalArgumentException("invalid security configuration value");
        }
    }

    private static GeordiPermission permission(String value) {
        return Arrays.stream(GeordiPermission.values()).filter(permission -> permission.publicName().equals(value))
                .findFirst().orElseThrow(() -> new IllegalArgumentException("unknown configured permission"));
    }

    @Override
    public String toString() {
        return "SecurityProperties[redacted]";
    }
}
