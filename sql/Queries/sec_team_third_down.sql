-- Team offense by conference and season: 3rd-down performance, play calling,
-- plays and drives per quarter/half/game, and average drive length.
-- Change the season or conference in `params`.
-- Source: core.plays, scrimmage plays only (down 1-4, run or pass; penalties,
-- kicks and 2-pt tries excluded; sacks count as pass plays).
-- Notes:
--   * A drive counts only if the team ran at least one scrimmage play on it
--     (the API also files kickoffs as the kicking team's own "drive").
--   * A drive belongs to the quarter/half its first scrimmage play was in.
--   * Drive yards = sum of yards gained on scrimmage plays (penalty yards not included).
--   * Per-game values divide by games played; overtime counts toward full-game
--     totals but not toward any quarter or half.
WITH params AS (
    SELECT 2026 AS season, 'SEC' AS conf
),
plays AS (
    SELECT p.*
    FROM core.plays p
    JOIN params x ON x.season = p.season AND x.conf = p.offense_conf
    WHERE p.is_scrimmage
),
games AS (
    SELECT offense AS team, count(DISTINCT game_id) AS games
    FROM plays
    GROUP BY offense
),
third_down AS (
    SELECT
        offense                                                 AS team,
        count(*)                                                AS third_down_plays,
        count(*) FILTER (WHERE play_category = 'pass')          AS third_down_pass_plays,
        count(*) FILTER (WHERE play_category = 'rush')          AS third_down_rush_plays,
        round(avg(distance), 2)                                 AS third_down_avg_distance,
        round(avg(off_yards), 2)                                AS third_down_avg_yards_gained,
        round(avg((off_yards >= distance)::int), 3)             AS third_down_conversion_rate,

        -- pass vs rush on 3rd down (sacks count as pass plays)
        count(*) FILTER (WHERE play_category = 'pass' AND off_yards >= distance)            AS third_down_pass_conv,
        round(avg((off_yards >= distance)::int) FILTER (WHERE play_category = 'pass'), 3)   AS third_down_pass_conv_rate,
        round(avg(distance) FILTER (WHERE play_category = 'pass'), 2)                       AS third_down_pass_avg_to_go,
        count(*) FILTER (WHERE play_category = 'rush' AND off_yards >= distance)            AS third_down_rush_conv,
        round(avg((off_yards >= distance)::int) FILTER (WHERE play_category = 'rush'), 3)   AS third_down_rush_conv_rate,
        round(avg(distance) FILTER (WHERE play_category = 'rush'), 2)                       AS third_down_rush_avg_to_go
    FROM plays
    WHERE down = 3
    GROUP BY offense
),
play_calls AS (
    SELECT
        offense                                                 AS team,
        count(*)                                                AS total_plays,
        count(*) FILTER (WHERE play_category = 'pass')          AS pass_plays,
        count(*) FILTER (WHERE play_category = 'rush')          AS rush_plays,
        count(*) FILTER (WHERE period = 1)                      AS q1_plays,
        count(*) FILTER (WHERE period = 2)                      AS q2_plays,
        count(*) FILTER (WHERE period = 3)                      AS q3_plays,
        count(*) FILTER (WHERE period = 4)                      AS q4_plays
    FROM plays
    GROUP BY offense
),
drives AS (
    -- one row per drive: where it started, how many plays, how many yards
    SELECT
        offense                                                 AS team,
        drive_id,
        (array_agg(period ORDER BY period, clock_sec DESC))[1]  AS start_period,
        count(*)                                                AS plays,
        sum(off_yards)                                          AS yards
    FROM plays
    GROUP BY offense, drive_id
),
drive_stats AS (
    SELECT
        team,
        count(*)                                                AS drives,
        count(*) FILTER (WHERE start_period = 1)                AS q1_drives,
        count(*) FILTER (WHERE start_period = 2)                AS q2_drives,
        count(*) FILTER (WHERE start_period = 3)                AS q3_drives,
        count(*) FILTER (WHERE start_period = 4)                AS q4_drives,
        round(avg(plays), 2)                                    AS avg_plays_per_drive,
        round(avg(plays) FILTER (WHERE start_period IN (1, 2)), 2) AS avg_plays_per_drive_1st_half,
        round(avg(plays) FILTER (WHERE start_period IN (3, 4)), 2) AS avg_plays_per_drive_2nd_half,
        round(avg(plays) FILTER (WHERE start_period = 1), 2)    AS avg_plays_per_drive_q1,
        round(avg(plays) FILTER (WHERE start_period = 2), 2)    AS avg_plays_per_drive_q2,
        round(avg(plays) FILTER (WHERE start_period = 3), 2)    AS avg_plays_per_drive_q3,
        round(avg(plays) FILTER (WHERE start_period = 4), 2)    AS avg_plays_per_drive_q4,
        round(avg(yards), 1)                                    AS avg_yards_per_drive
    FROM drives
    GROUP BY team
)
SELECT
    g.team,
    g.games,

    -- ---------- 3rd down ----------
    t.third_down_plays,
    t.third_down_pass_plays,
    t.third_down_rush_plays,
    t.third_down_avg_distance,
    t.third_down_avg_yards_gained,
    t.third_down_conversion_rate,
    t.third_down_pass_conv,
    t.third_down_pass_conv_rate,
    t.third_down_pass_avg_to_go,
    t.third_down_rush_conv,
    t.third_down_rush_conv_rate,
    t.third_down_rush_avg_to_go,

    -- ---------- play calling ----------
    c.pass_plays,
    c.rush_plays,
    round(c.pass_plays::numeric / c.total_plays, 3)             AS pass_rate,
    round(c.pass_plays::numeric / g.games, 1)                   AS pass_plays_per_game,
    round(c.rush_plays::numeric / g.games, 1)                   AS rush_plays_per_game,

    -- ---------- plays per game ----------
    round(c.total_plays::numeric / g.games, 1)                  AS plays_per_game,
    round((c.q1_plays + c.q2_plays)::numeric / g.games, 1)      AS plays_per_1st_half,
    round((c.q3_plays + c.q4_plays)::numeric / g.games, 1)      AS plays_per_2nd_half,
    round(c.q1_plays::numeric / g.games, 1)                     AS plays_per_q1,
    round(c.q2_plays::numeric / g.games, 1)                     AS plays_per_q2,
    round(c.q3_plays::numeric / g.games, 1)                     AS plays_per_q3,
    round(c.q4_plays::numeric / g.games, 1)                     AS plays_per_q4,

    -- ---------- drives per game ----------
    round(d.drives::numeric / g.games, 1)                       AS drives_per_game,
    round((d.q1_drives + d.q2_drives)::numeric / g.games, 1)    AS drives_per_1st_half,
    round((d.q3_drives + d.q4_drives)::numeric / g.games, 1)    AS drives_per_2nd_half,
    round(d.q1_drives::numeric / g.games, 1)                    AS drives_per_q1,
    round(d.q2_drives::numeric / g.games, 1)                    AS drives_per_q2,
    round(d.q3_drives::numeric / g.games, 1)                    AS drives_per_q3,
    round(d.q4_drives::numeric / g.games, 1)                    AS drives_per_q4,

    -- ---------- drive length (by the quarter/half the drive started in) ----------
    d.avg_plays_per_drive,
    d.avg_plays_per_drive_1st_half,
    d.avg_plays_per_drive_2nd_half,
    d.avg_plays_per_drive_q1,
    d.avg_plays_per_drive_q2,
    d.avg_plays_per_drive_q3,
    d.avg_plays_per_drive_q4,
    d.avg_yards_per_drive
FROM games g
JOIN third_down  t USING (team)
JOIN play_calls  c USING (team)
JOIN drive_stats d USING (team)
ORDER BY t.third_down_conversion_rate DESC;
