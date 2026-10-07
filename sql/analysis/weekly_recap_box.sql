-- Weekly recap: the team's game in `week`, one row per stat, the team vs. its
-- opponent, plus the team's average coming in (its earlier games this season).
-- Change team / season / week in `params` (the notebook weekly_report.ipynb sets them).
-- Source: core.team_games (official box score + play-by-play PPA + drive stats).
-- Notes:
--   * yards per play = total yards / (pass attempts + rush attempts); sacks count
--     as rushes in official stats.
--   * PPA and success rate are per scrimmage play, garbage time included.
--   * team_avg_before is NULL in the team's first game.
WITH params AS (
    SELECT 'Auburn'::text AS team, 2026 AS season, 5 AS week
),
g AS (
    -- the team's game that week
    SELECT t.*
    FROM core.team_games t
    JOIN params x ON x.team = t.team AND x.season = t.season AND x.week = t.week
                AND t.season_type = 'regular'   -- postseason weeks restart at 1
),
o AS (
    -- the opponent's side of the same game
    SELECT t.*
    FROM core.team_games t
    JOIN g ON g.game_id = t.game_id AND t.team = g.opponent
),
prior AS (
    -- the team's earlier games this season
    SELECT
        count(*)                                                              AS games,
        avg(t.points_for)                                                     AS points,
        avg(t.total_yards)                                                    AS total_yards,
        sum(t.total_yards)::numeric / NULLIF(sum(t.pass_att + t.rush_att), 0) AS yards_per_play,
        avg(t.pass_yards)                                                     AS pass_yards,
        avg(t.rush_yards)                                                     AS rush_yards,
        sum(t.rush_yards)::numeric / NULLIF(sum(t.rush_att), 0)               AS yards_per_rush,
        sum(t.third_conv)::numeric / NULLIF(sum(t.third_att), 0)              AS third_down_pct,
        avg(t.turnovers)                                                      AS turnovers,
        avg(t.penalty_yards)                                                  AS penalty_yards,
        avg(t.possession_sec) / 60.0                                          AS possession_min,
        sum(t.off_ppa * t.off_plays) / NULLIF(sum(t.off_plays), 0)            AS ppa_per_play,
        sum(t.off_success_rate * t.off_plays) / NULLIF(sum(t.off_plays), 0)   AS success_rate,
        sum(t.points_for)::numeric / NULLIF(sum(t.drives), 0)                 AS points_per_drive,
        avg(t.three_and_outs)                                                 AS three_and_outs,
        avg(t.avg_start_yards_to_goal)                                        AS start_yards_to_goal
    FROM core.team_games t
    JOIN params x ON x.team = t.team AND x.season = t.season AND t.week < x.week
                AND t.season_type = 'regular'
)
SELECT
    g.week,
    g.team,
    g.opponent,
    g.location,
    v.metric,
    round(v.team_value, 3)                                                    AS team_value,
    round(v.opp_value, 3)                                                     AS opp_value,
    round(v.team_avg_before, 3)                                               AS team_avg_before,
    v.higher_is_better
FROM g
JOIN o ON true
CROSS JOIN prior p
CROSS JOIN LATERAL (VALUES
    (1,  'Points',                g.points_for::numeric,     o.points_for::numeric,     p.points,           true),
    (2,  'Total yards',           g.total_yards::numeric,    o.total_yards::numeric,    p.total_yards,      true),
    (3,  'Yards per play',        g.total_yards::numeric / NULLIF(g.pass_att + g.rush_att, 0),
                                  o.total_yards::numeric / NULLIF(o.pass_att + o.rush_att, 0),
                                                                                        p.yards_per_play,   true),
    (4,  'Passing yards',         g.pass_yards::numeric,     o.pass_yards::numeric,     p.pass_yards,       true),
    (5,  'Rushing yards',         g.rush_yards::numeric,     o.rush_yards::numeric,     p.rush_yards,       true),
    (6,  'Yards per rush',        g.rush_yards::numeric / NULLIF(g.rush_att, 0),
                                  o.rush_yards::numeric / NULLIF(o.rush_att, 0),         p.yards_per_rush,   true),
    (7,  '3rd down conversion',   g.third_conv::numeric / NULLIF(g.third_att, 0),
                                  o.third_conv::numeric / NULLIF(o.third_att, 0),       p.third_down_pct,   true),
    (8,  'Turnovers',             g.turnovers::numeric,      o.turnovers::numeric,      p.turnovers,        false),
    (9,  'Penalty yards',         g.penalty_yards::numeric,  o.penalty_yards::numeric,  p.penalty_yards,    false),
    (10, 'Possession (min)',      g.possession_sec / 60.0,   o.possession_sec / 60.0,   p.possession_min,   true),
    (11, 'PPA per play',          g.off_ppa,                 o.off_ppa,                 p.ppa_per_play,     true),
    (12, 'Success rate',          g.off_success_rate,        o.off_success_rate,        p.success_rate,     true),
    (13, 'Points per drive',      g.points_per_drive,        o.points_per_drive,        p.points_per_drive, true),
    (14, 'Three-and-outs',        g.three_and_outs::numeric, o.three_and_outs::numeric, p.three_and_outs,   false),
    (15, 'Avg start (yds to goal)', g.avg_start_yards_to_goal, o.avg_start_yards_to_goal, p.start_yards_to_goal, false)
) AS v(sort, metric, team_value, opp_value, team_avg_before, higher_is_better)
ORDER BY v.sort;
