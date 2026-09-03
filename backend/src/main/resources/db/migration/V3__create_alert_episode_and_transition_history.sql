CREATE TABLE alert_episode (
    episode_id VARCHAR(64) PRIMARY KEY,
    policy_id VARCHAR(64) NOT NULL,
    opened_at TIMESTAMP WITH TIME ZONE,
    closed_at TIMESTAMP WITH TIME ZONE,
    origin VARCHAR(32) NOT NULL,
    open_policy_id VARCHAR(64) GENERATED ALWAYS AS
        (CASE WHEN closed_at IS NULL THEN policy_id ELSE NULL END),
    CONSTRAINT alert_episode_open_policy_unique UNIQUE (open_policy_id),
    CONSTRAINT alert_episode_origin_opened_at_check CHECK (
        (origin = 'M14' AND opened_at IS NOT NULL)
        OR (origin = 'PRE_M14_UNKNOWN_START' AND opened_at IS NULL)
    ),
    CONSTRAINT alert_episode_time_order_check CHECK (opened_at IS NULL OR closed_at IS NULL OR closed_at >= opened_at)
);

CREATE TABLE alert_transition_history (
    transition_id VARCHAR(64) PRIMARY KEY,
    episode_id VARCHAR(64) NOT NULL,
    policy_id VARCHAR(64) NOT NULL,
    transition_type VARCHAR(32) NOT NULL,
    occurred_at TIMESTAMP WITH TIME ZONE NOT NULL,
    previous_state VARCHAR(16) NOT NULL,
    current_state VARCHAR(16) NOT NULL,
    transition_json CHARACTER LARGE OBJECT NOT NULL,
    CONSTRAINT alert_transition_history_episode_fk
        FOREIGN KEY (episode_id) REFERENCES alert_episode (episode_id),
    CONSTRAINT alert_transition_history_transition_unique
        UNIQUE (policy_id, transition_type, occurred_at)
);

CREATE INDEX alert_episode_policy_opened_at_idx ON alert_episode (policy_id, opened_at DESC, episode_id DESC);
CREATE INDEX alert_transition_history_policy_occurred_at_idx
    ON alert_transition_history (policy_id, occurred_at DESC, transition_id DESC);
CREATE INDEX alert_transition_history_episode_occurred_at_idx
    ON alert_transition_history (episode_id, occurred_at DESC, transition_id DESC);
