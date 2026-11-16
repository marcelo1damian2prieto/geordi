-- Frozen before M19 persistence/domain edits, from baseline 2601a4ee63924e843a50dc8940a8e193709e2f5b.
-- Deliberately uses the original V7 INSERT column set. Never regenerate from M19 objects.
INSERT INTO alert_episode (episode_id, policy_id, opened_at, closed_at, origin)
VALUES (REPEAT('a', 64), 'm19-legacy-null', TIMESTAMP WITH TIME ZONE '2026-08-27 16:00:00+00', NULL, 'M14');
INSERT INTO alert_episode (episode_id, policy_id, opened_at, closed_at, origin)
VALUES (REPEAT('b', 64), 'm19-legacy-unicode', TIMESTAMP WITH TIME ZONE '2026-08-27 16:00:00+00', NULL, 'M14');
INSERT INTO alert_episode_acknowledgement (episode_id, actor, reason, acknowledged_at)
VALUES (REPEAT('a', 64), 'Operator', NULL, TIMESTAMP WITH TIME ZONE '2026-08-27 16:00:00.123456789+00');
INSERT INTO alert_episode_acknowledgement (episode_id, actor, reason, acknowledged_at)
VALUES (REPEAT('b', 64), 'Operador 😀', 'Revisión 🚀', TIMESTAMP WITH TIME ZONE '2026-08-27 16:00:01.987654321+00');
