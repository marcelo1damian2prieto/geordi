ALTER TABLE alert_episode_acknowledgement
    ADD COLUMN identity_provenance VARCHAR(32) NOT NULL DEFAULT 'LEGACY_CALLER_ASSERTED';
ALTER TABLE alert_episode_acknowledgement
    ADD COLUMN principal_issuer VARCHAR(2048) NULL;
ALTER TABLE alert_episode_acknowledgement
    ADD COLUMN principal_subject VARCHAR(255) NULL;
ALTER TABLE alert_episode_acknowledgement
    ADD COLUMN display_name_snapshot VARCHAR(256) NULL;

ALTER TABLE alert_episode_acknowledgement
    ADD CONSTRAINT alert_acknowledgement_attribution_check CHECK (
        (identity_provenance = 'LEGACY_CALLER_ASSERTED'
            AND principal_issuer IS NULL AND principal_subject IS NULL AND display_name_snapshot IS NULL)
        OR
        (identity_provenance = 'AUTHENTICATED_PRINCIPAL'
            AND principal_issuer IS NOT NULL AND CHAR_LENGTH(principal_issuer) > 0
            AND principal_subject IS NOT NULL AND CHAR_LENGTH(principal_subject) > 0)
    );
