CREATE TABLE alert_episode_acknowledgement (
    episode_id VARCHAR(64) PRIMARY KEY,
    actor VARCHAR(128) NOT NULL,
    reason VARCHAR(512),
    acknowledged_at TIMESTAMP(9) WITH TIME ZONE NOT NULL,
    CONSTRAINT alert_episode_acknowledgement_episode_fk
        FOREIGN KEY (episode_id) REFERENCES alert_episode (episode_id)
);
