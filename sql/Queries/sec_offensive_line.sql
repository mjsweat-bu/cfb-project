-- Offensive line as a unit, by conference and season: run blocking (line yards,
-- stuff rate, power success, second-level / open-field yards, by run direction),
-- pass protection (sack rate, QB hurries allowed) and O-line penalties.
-- Change the season or conference in `params`.
-- Source: core.plays (scrimmage plays, garbage time excluded as in
-- sec_team_ppa.sql); raw.api_player_seasons roster to tell which penalized
-- players are offensive linemen.
-- Notes:
--   * There is no per-lineman blocking data, so these are unit stats. Per-player
--     penalties are in sec_offensive_line_players.sql.
--   * Runs = rush plays, excluding kneel-downs. QB scrambles count as runs
--     (the play text doesn't separate them from designed runs); sacks count as
--     pass plays, not runs.
--   * line_yards_per_rush: each run's yards credited to the line as
--     losses x 1.2, yards 0-4 x 1.0, yards 5-10 x 0.5, yards 11+ x 0
--     (the standard line-yards formula; long runs are mostly the runner's).
--     Runs a little higher than the API's off_line_yards in
--     marts.team_season_stats, which counts a slightly different set of runs.
--   * second_level_yards = yards 5-10 per rush, open_field_yards = yards beyond
--     10 per rush (both averaged over all rushes, so they're "per carry" values).
--   * stuff_pct = runs for 0 or fewer yards. power_pct = 3rd/4th-down runs with
--     2 or fewer yards to go that converted.
--   * Run direction is parsed from "rush left / middle / right" in play_text.
--   * Dropbacks = pass plays including sacks. hurries = "hurried by" in play_text
--     (only plays in the ESPN text format; see team_text_pct).
--   * ol_penalties: accepted penalties on players listed as OL/OT/G/C on the
--     offense's roster. pre_snap = false start, illegal snap/formation/motion/shift.
--   * Ranks: 1 = best in the conference (lowest for stuff %, sack %, hurries,
--     penalties).
WITH params AS (
    SELECT 2026 AS season, 'SEC' AS conf
),
plays AS (
    SELECT p.*,
           substring(p.play_text FROM 'rush (left|middle|right)') AS run_dir
    FROM core.plays p
    JOIN params x ON x.season = p.season AND x.conf = p.offense_conf
    WHERE p.is_scrimmage
      AND NOT (   (p.period = 2 AND abs(p.offense_score - p.defense_score) > 38)
               OR (p.period = 3 AND abs(p.offense_score - p.defense_score) > 28)
               OR (p.period = 4 AND abs(p.offense_score - p.defense_score) > 22))
),
runs AS (
    SELECT *,
           CASE WHEN off_yards < 0  THEN 1.2 * off_yards
                WHEN off_yards <= 4 THEN off_yards
                WHEN off_yards <= 10 THEN 4 + 0.5 * (off_yards - 4)
                ELSE 4 + 0.5 * 6 END                                 AS line_yards,
           least(greatest(off_yards - 4, 0), 6)                      AS second_level,
           greatest(off_yards - 10, 0)                               AS open_field
    FROM plays
    WHERE play_category = 'rush'
      AND play_text NOT ILIKE '%kneel%'
),
run_unit AS (
    SELECT
        offense                                                         AS team,
        count(DISTINCT game_id)                                         AS games,
        count(*)                                                        AS rushes,
        round(avg(off_yards), 2)                                        AS yards_per_rush,
        round(avg(line_yards), 2)                                       AS line_yards_per_rush,
        round(avg(second_level), 2)                                     AS second_level_yards,
        round(avg(open_field), 2)                                       AS open_field_yards,
        round(avg((off_yards <= 0)::int) * 100, 1)                      AS stuff_pct,
        count(*) FILTER (WHERE down IN (3, 4) AND distance <= 2)        AS power_runs,
        round(avg((off_yards >= distance)::int)
              FILTER (WHERE down IN (3, 4) AND distance <= 2) * 100, 1) AS power_pct,
        round(avg(is_success::int) * 100, 1)                            AS rush_success_pct,
        round(avg(ppa), 3)                                              AS rush_ppa,

        -- by side of the line
        count(*) FILTER (WHERE run_dir = 'left')                        AS runs_left,
        round(avg(line_yards) FILTER (WHERE run_dir = 'left'), 2)       AS line_yards_left,
        round(avg((off_yards <= 0)::int) FILTER (WHERE run_dir = 'left') * 100, 1) AS stuff_pct_left,
        count(*) FILTER (WHERE run_dir = 'middle')                      AS runs_middle,
        round(avg(line_yards) FILTER (WHERE run_dir = 'middle'), 2)     AS line_yards_middle,
        round(avg((off_yards <= 0)::int) FILTER (WHERE run_dir = 'middle') * 100, 1) AS stuff_pct_middle,
        count(*) FILTER (WHERE run_dir = 'right')                       AS runs_right,
        round(avg(line_yards) FILTER (WHERE run_dir = 'right'), 2)      AS line_yards_right,
        round(avg((off_yards <= 0)::int) FILTER (WHERE run_dir = 'right') * 100, 1) AS stuff_pct_right
    FROM runs
    GROUP BY offense
),
pass_unit AS (
    SELECT
        offense                                                         AS team,
        count(*)                                                        AS dropbacks,
        count(*) FILTER (WHERE play_type = 'Sack')                      AS sacks,
        round(avg((play_type = 'Sack')::int) * 100, 1)                  AS sack_pct,
        count(*) FILTER (WHERE play_text ~ 'hurried by')                AS hurries,
        round(avg((play_type = 'Sack' OR play_text ~ 'hurried by')::int) * 100, 1) AS pressure_pct,
        round(avg((play_text ~ '#\d+')::int) * 100, 1)                  AS team_text_pct
    FROM plays
    WHERE play_category = 'pass'
    GROUP BY offense
),
penalties AS (
    -- every player penalty in the season's plays, kept when the player is an
    -- offensive lineman on the offense's roster (all plays, incl. penalty-only)
    SELECT p.offense AS team, p.play_id, m[1] AS foul
    FROM core.plays p
    JOIN params x ON x.season = p.season AND x.conf = p.offense_conf
    CROSS JOIN LATERAL regexp_matches(p.play_text,
        'PENALTY ([^(#]+) \(#(\d+) ([^)]+)\)\s*(declined|offsetting)?', 'g') m
    WHERE m[4] IS NULL
      AND EXISTS (
          SELECT 1 FROM raw.api_player_seasons r
          WHERE r.endpoint = 'roster' AND r.season = x.season
            AND r.payload->>'team' = p.offense
            AND r.payload->>'position' IN ('OL', 'OT', 'G', 'C')
            AND (r.payload->>'jersey')::int = m[2]::int
            AND lower(m[3]) LIKE '%' || lower(split_part(r.payload->>'lastName', ' ', 1)) || '%')
),
pen_unit AS (
    SELECT team,
           count(*)                                                      AS ol_penalties,
           count(*) FILTER (WHERE foul ILIKE '%holding%')                AS ol_holding,
           count(*) FILTER (WHERE foul ~* 'false start|illegal (snap|formation|motion|shift)') AS ol_pre_snap
    FROM penalties
    GROUP BY team
),
teams AS (
    SELECT r.*, p.dropbacks, p.sacks, p.sack_pct, p.hurries, p.pressure_pct, p.team_text_pct,
           coalesce(n.ol_penalties, 0)                                    AS ol_penalties,
           coalesce(n.ol_holding, 0)                                      AS ol_holding,
           coalesce(n.ol_pre_snap, 0)                                     AS ol_pre_snap,
           round(coalesce(n.ol_penalties, 0)::numeric / r.games, 2)       AS ol_penalties_per_game
    FROM run_unit r
    JOIN pass_unit p USING (team)
    LEFT JOIN pen_unit n USING (team)
)
SELECT
    team, games,
    -- run blocking
    rushes, yards_per_rush,
    line_yards_per_rush,  rank() OVER (ORDER BY line_yards_per_rush DESC) AS line_yards_rank,
    stuff_pct,            rank() OVER (ORDER BY stuff_pct)                AS stuff_rank,
    power_runs, power_pct, rank() OVER (ORDER BY power_pct DESC NULLS LAST) AS power_rank,
    second_level_yards, open_field_yards,
    rush_success_pct, rush_ppa,
    runs_left, line_yards_left, stuff_pct_left,
    runs_middle, line_yards_middle, stuff_pct_middle,
    runs_right, line_yards_right, stuff_pct_right,
    -- pass protection
    dropbacks, sacks,
    sack_pct,             rank() OVER (ORDER BY sack_pct)                 AS sack_rank,
    hurries, pressure_pct, rank() OVER (ORDER BY pressure_pct)            AS pressure_rank,
    -- penalties
    ol_penalties, ol_holding, ol_pre_snap,
    ol_penalties_per_game, rank() OVER (ORDER BY ol_penalties_per_game)   AS penalty_rank,
    team_text_pct
FROM teams
ORDER BY line_yards_per_rush DESC;
