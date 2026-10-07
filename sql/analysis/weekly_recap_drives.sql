-- Weekly recap: every drive of the team's game in `week`, both teams, in order.
-- Change team / season / week in `params` (the notebook weekly_report.ipynb sets them).
-- Source: core.drives (possessions with at least one snap, punt or FG try).
-- Notes:
--   * Field position is from the offense's side: 'own 25' = 75 yards to goal,
--     'opp 40' = 40 yards to goal. start_yards_from_own_goal / end_... are the
--     same as numbers (0 = own goal line, 100 = opponent's), for the drive chart.
--     The end is the spot of the drive's last snap (the API has no end-of-play
--     spot), except TD drives, which end at 100.
--   * Clock is at the drive's first snap; OT drives show period 5+ and no clock.
--   * Score is the offense's lead before the drive (negative = trailing).
WITH params AS (
    SELECT 'Auburn'::text AS team, 2026 AS season, 5 AS week
),
g AS (
    SELECT t.game_id, t.team, t.opponent
    FROM core.team_games t
    JOIN params x ON x.team = t.team AND x.season = t.season AND x.week = t.week
                AND t.season_type = 'regular'   -- postseason weeks restart at 1
)
SELECT
    row_number() OVER (ORDER BY d.drive_number, d.drive_id)          AS drive_order,
    d.offense,
    d.offense = g.team                                               AS is_team,
    d.start_period                                                   AS quarter,
    CASE WHEN d.start_period <= 4
         THEN to_char(make_interval(secs => d.start_clock_sec), 'MI:SS') END AS clock,
    CASE WHEN d.start_yards_to_goal > 50 THEN 'own ' || (100 - d.start_yards_to_goal)
         WHEN d.start_yards_to_goal = 50 THEN 'midfield'
         ELSE 'opp ' || d.start_yards_to_goal END                    AS start,
    d.plays,
    d.yards,
    d.result,
    d.start_margin                                                   AS lead_before,
    d.third_conv || '/' || d.third_att                               AS third_downs,
    round(d.ppa_total, 2)                                            AS ppa_total,
    100 - d.start_yards_to_goal                                      AS start_yards_from_own_goal,
    CASE WHEN d.result = 'TD' THEN 100
         ELSE 100 - d.end_yards_to_goal END                          AS end_yards_from_own_goal
FROM core.drives d
JOIN g ON g.game_id = d.game_id
ORDER BY drive_order;
