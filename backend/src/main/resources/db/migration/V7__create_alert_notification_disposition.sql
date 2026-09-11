CREATE TABLE alert_notification_disposition (
    transition_id VARCHAR(64) PRIMARY KEY,
    disposition VARCHAR(16) NOT NULL,

    CONSTRAINT alert_notification_disposition_transition_fk
        FOREIGN KEY (transition_id)
        REFERENCES alert_transition_history (transition_id),

    CONSTRAINT alert_notification_disposition_value_check
        CHECK (disposition IN ('MATCHED', 'SUPPRESSED', 'UNROUTED'))
);
