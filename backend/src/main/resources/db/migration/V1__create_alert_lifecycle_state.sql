CREATE TABLE alert_lifecycle_state (
    policy_id VARCHAR(64) PRIMARY KEY,
    version BIGINT NOT NULL,
    aggregate_json CHARACTER LARGE OBJECT NOT NULL
);
