-- Offensive linemen across a conference for one season: penalties by player
-- (the only per-lineman stat in play-by-play data), with the plays and yards
-- they cost.
-- Change the season or conference in `params`.
-- Source: core.plays (all plays, including penalty-only plays),
-- raw.api_player_seasons roster for name, position, class, height and weight.
-- Notes:
--   * Penalized players are parsed from play_text in the ESPN format, e.g.
--       "PENALTY AUB Holding (#72 C.Best) 10 yards from AUB46 to AUB36. NO PLAY"
--     and kept when they match an OL/OT/G/C on the offense's roster (last name
--     + jersey, or last name + first initial). Declined/offsetting penalties
--     are left out.
--   * Only linemen with at least one accepted penalty appear: the data has no
--     snap counts, so a lineman with no penalties can't be told apart from one
--     who didn't play. team_ol_snaps (the team's offensive plays) is the
--     denominator for per-100-snap rates; it overstates each player's snaps if
--     he missed games or rotated, so per-100 rates are a floor.
--   * pre_snap = false start, illegal snap/formation/motion/shift.
--     holding includes "holding" and "illegal use of hands".
--   * yards_wiped_out = offensive gain erased by the penalty (a run or catch
--     that was called back, "NO PLAY"), e.g. a 52-yard TD nullified by holding.
--   * drive_killers = penalties on 3rd or 4th down, or that wiped out a
--     touchdown.
WITH params AS (
    SELECT 2026 AS season, 'SEC' AS conf
),
team_plays AS (
    SELECT p.offense AS team, count(*) AS team_ol_snaps, count(DISTINCT p.game_id) AS team_games
    FROM core.plays p
    JOIN params x ON x.season = p.season AND x.conf = p.offense_conf
    WHERE p.is_scrimmage
    GROUP BY p.offense
),
fouls AS (
    SELECT p.offense AS team, p.play_id, p.game_id, p.down, p.play_text,
           btrim(m[1])                                                 AS foul_text,
           m[2]::int                                                   AS jersey,
           btrim(replace(m[3], ',', ''))                               AS name,
           substring(p.play_text FROM '\(#\d+ [^)]+\)\s*(\d+) yards? from')::int AS pen_yards,
           -- gain on the snap before the flag, when the play was wiped out
           CASE WHEN p.play_text ~ 'NO PLAY'
                THEN substring(split_part(p.play_text, 'PENALTY', 1)
                               FROM 'for (\d+) yards? (?:gain|to)')::int END AS gain_erased,
           (p.play_text ~ 'NO PLAY' AND split_part(p.play_text, 'PENALTY', 1) ~ 'TOUCHDOWN') AS td_erased
    FROM core.plays p
    JOIN params x ON x.season = p.season AND x.conf = p.offense_conf
    CROSS JOIN LATERAL regexp_matches(p.play_text,
        'PENALTY ([^(#]+) \(#(\d+) ([^)]+)\)\s*(declined|offsetting)?', 'g') m
    WHERE m[4] IS NULL
),
ol_fouls AS (
    SELECT f.*, r.payload
    FROM fouls f
    CROSS JOIN params x
    JOIN LATERAL (
        SELECT payload
        FROM raw.api_player_seasons r
        WHERE r.endpoint = 'roster'
          AND r.season = x.season
          AND r.payload->>'team' = f.team
          AND r.payload->>'position' IN ('OL', 'OT', 'G', 'C')
          AND lower(f.name) LIKE '%' || lower(split_part(r.payload->>'lastName', ' ', 1)) || '%'
          AND (   (r.payload->>'jersey')::int = f.jersey
               OR upper(left(r.payload->>'firstName', 1)) = upper(left(f.name, 1)))
        ORDER BY ((r.payload->>'jersey')::int = f.jersey) DESC
        LIMIT 1
    ) r ON true
),
players AS (
    SELECT
        payload->>'id'                                                   AS player_id,
        max(payload->>'firstName' || ' ' || (payload->>'lastName'))      AS player,
        team,
        max(payload->>'position')                                        AS pos,
        max((payload->>'jersey')::int)                                   AS jersey,
        max((payload->>'year')::int)                                     AS class_year,
        max((payload->>'height')::int)                                   AS height_in,
        max((payload->>'weight')::int)                                   AS weight_lb,
        count(*)                                                         AS penalties,
        count(*) FILTER (WHERE foul_text ~* 'holding|illegal use of hands')            AS holding,
        count(*) FILTER (WHERE foul_text ~* 'false start|illegal (snap|formation|motion|shift)') AS pre_snap,
        count(*) FILTER (WHERE foul_text !~* 'holding|illegal use of hands|false start|illegal (snap|formation|motion|shift)') AS other,
        string_agg(DISTINCT regexp_replace(foul_text, '^\S+\s+', ''), ', ') AS foul_types,
        coalesce(sum(pen_yards), 0)                                      AS penalty_yards,
        coalesce(sum(gain_erased), 0)                                    AS yards_wiped_out,
        count(*) FILTER (WHERE td_erased)                                AS tds_wiped_out,
        count(*) FILTER (WHERE down IN (3, 4) OR td_erased)              AS drive_killers
    FROM ol_fouls
    GROUP BY payload->>'id', team
)
SELECT
    pl.player, pl.team, pl.pos, pl.jersey, pl.class_year, pl.height_in, pl.weight_lb,
    pl.penalties, pl.holding, pl.pre_snap, pl.other, pl.foul_types,
    pl.penalty_yards, pl.yards_wiped_out, pl.tds_wiped_out, pl.drive_killers,
    t.team_games, t.team_ol_snaps,
    round(pl.penalties * 100.0 / t.team_ol_snaps, 2)                     AS penalties_per_100_snaps,
    round((pl.penalty_yards + pl.yards_wiped_out)::numeric / t.team_games, 1) AS yards_cost_per_game
FROM players pl
JOIN team_plays t USING (team)
ORDER BY pl.penalties DESC, pl.penalty_yards + pl.yards_wiped_out DESC;
