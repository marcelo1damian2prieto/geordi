CREATE TABLE alert_notification_outbox (
    delivery_id VARCHAR(64) PRIMARY KEY,
    policy_id VARCHAR(64) NOT NULL,
    transition_type VARCHAR(32) NOT NULL,
    occurred_at TIMESTAMP WITH TIME ZONE NOT NULL,
    destination_id VARCHAR(128) NOT NULL,
    destination_fingerprint VARCHAR(128) NOT NULL,
    payload_json CHARACTER LARGE OBJECT NOT NULL,
    state VARCHAR(16) NOT NULL,
    attempts INTEGER NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL,
    next_attempt_at TIMESTAMP WITH TIME ZONE NOT NULL,
    claim_token VARCHAR(64),
    lease_expires_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    CONSTRAINT alert_notification_outbox_transition_unique
        UNIQUE (policy_id, transition_type, occurred_at)
);
