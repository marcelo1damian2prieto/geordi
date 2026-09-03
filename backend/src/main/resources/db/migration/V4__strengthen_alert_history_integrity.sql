ALTER TABLE alert_transition_history
    ALTER COLUMN occurred_at TIMESTAMP(9) WITH TIME ZONE;

UPDATE alert_transition_history
SET occurred_at = DATEADD(
    NANOSECOND,
    CAST(ABS(
        CAST(CASE WHEN CAST(transition_json AS VARCHAR(1000000)) IS JSON OBJECT THEN REGEXP_REPLACE(
            CAST(transition_json AS VARCHAR(1000000)),
            '.*"occurredAt":((-?[0-9]+[.][0-9]{1,9})|([0-9]+([.][0-9]{1,8})?E-[0-9]+)),.*',
            '$1'
        ) ELSE CAST(transition_json AS VARCHAR(1000000)) END AS DECIMAL(29, 9))
        - TRUNC(CAST(CASE WHEN CAST(transition_json AS VARCHAR(1000000)) IS JSON OBJECT THEN REGEXP_REPLACE(
            CAST(transition_json AS VARCHAR(1000000)),
            '.*"occurredAt":((-?[0-9]+[.][0-9]{1,9})|([0-9]+([.][0-9]{1,8})?E-[0-9]+)),.*',
            '$1'
        ) ELSE CAST(transition_json AS VARCHAR(1000000)) END AS DECIMAL(29, 9)))
    ) * 1000000000 AS BIGINT),
    DATEADD(
        SECOND,
        CAST(TRUNC(CAST(CASE WHEN CAST(transition_json AS VARCHAR(1000000)) IS JSON OBJECT THEN REGEXP_REPLACE(
            CAST(transition_json AS VARCHAR(1000000)),
            '.*"occurredAt":((-?[0-9]+[.][0-9]{1,9})|([0-9]+([.][0-9]{1,8})?E-[0-9]+)),.*',
            '$1'
        ) ELSE CAST(transition_json AS VARCHAR(1000000)) END AS DECIMAL(29, 9))) AS BIGINT),
        TIMESTAMP WITH TIME ZONE '1970-01-01 00:00:00+00'
    )
);

ALTER TABLE alert_episode
    ALTER COLUMN opened_at TIMESTAMP(9) WITH TIME ZONE;

ALTER TABLE alert_episode
    ALTER COLUMN closed_at TIMESTAMP(9) WITH TIME ZONE;

UPDATE alert_episode episode
SET opened_at = (
    SELECT transition.occurred_at
    FROM alert_transition_history transition
    WHERE transition.episode_id = episode.episode_id
      AND transition.transition_type = 'ALERT_STARTED'
)
WHERE episode.origin = 'M14';

UPDATE alert_episode episode
SET closed_at = (
    SELECT transition.occurred_at
    FROM alert_transition_history transition
    WHERE transition.episode_id = episode.episode_id
      AND transition.transition_type = 'ALERT_RESOLVED'
)
WHERE episode.closed_at IS NOT NULL;

ALTER TABLE alert_episode
    ADD CONSTRAINT alert_episode_legacy_closed_check
    CHECK (origin <> 'PRE_M14_UNKNOWN_START' OR (closed_at IS NOT NULL AND open_policy_id IS NULL));

ALTER TABLE alert_episode
    ADD CONSTRAINT alert_episode_id_policy_unique UNIQUE (episode_id, policy_id);

ALTER TABLE alert_transition_history
    ADD CONSTRAINT alert_transition_history_episode_policy_fk
    FOREIGN KEY (episode_id, policy_id) REFERENCES alert_episode (episode_id, policy_id);
