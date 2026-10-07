-- Weekly preview: the team vs. its next opponent, season to date (regular-season
-- games through `week`), with each value's rank among FBS teams (1 = best).
-- Change team / season / week in `params`. Uses the same next-game lookup as
-- weekly_preview_game.sql.
-- Source: core.team_games (official box score + play-by-play PPA + drive stats).
-- Notes:
--   * All of each team's games count, including FCS opponents.
--   * side = 'offense' / 'defense' (what the defense allowed) / 'overall'.
--     Pair the team's offense rows with the opponent's defense rows (same metric)
--     for a matchup view.
--   * PPA, success rate, yards per play and 3rd-down rate are per play / attempt
--     (weighted), not averages of per-game numbers.
--   * Ranks use min-rank ties; rank direction follows higher_is_better.
WITH params AS (
    SELECT 'Auburn'::text AS team, 2026 AS season, 5 AS week
),
next_opp AS (
    SELECT CASE WHEN r.payload->>'homeTeam' = x.team
                THEN r.payload->>'awayTeam' ELSE r.payload->>'homeTeam' END AS opponent
    FROM raw.api_games r
    JOIN params x ON x.season = r.season
    WHERE x.team IN (r.payload->>'homeTeam', r.payload->>'awayTeam')
      AND ((r.payload->>'seasonType') = 'postseason' OR (r.payload->>'week')::int > x.week)
    ORDER BY (r.payload->>'startDate')::timestamptz
    LIMIT 1
),
games AS (
    -- every FBS team's games this season through `week`, with the opponent's row
    SELECT t.*,
           o.pass_att AS opp_pass_att, o.rush_att AS opp_rush_att
    FROM core.team_games t
    JOIN core.team_games o ON o.game_id = t.game_id AND o.team = t.opponent
    JOIN params x ON x.season = t.season AND t.week <= x.week
    WHERE t.class = 'fbs'
      AND t.season_type = 'regular'   -- postseason weeks restart at 1
),
s AS (
    SELECT
        team,
        count(*)                                                                  AS games,
        -- overall
        avg(margin)                                                               AS margin_pg,
        avg(takeaways - turnovers)                                                AS turnover_margin_pg,
        -- offense
        avg(points_for)                                                           AS off_points_pg,
        sum(total_yards)::numeric / NULLIF(sum(pass_att + rush_att), 0)           AS off_yards_per_play,
        sum(off_ppa * off_plays) / NULLIF(sum(off_plays), 0)                      AS off_ppa,
        sum(off_success_rate * off_plays) / NULLIF(sum(off_plays), 0)             AS off_success_rate,
        sum(third_conv)::numeric / NULLIF(sum(third_att), 0)                      AS off_third_down_pct,
        sum(points_for)::numeric / NULLIF(sum(drives), 0)                         AS off_points_per_drive,
        sum(three_and_outs)::numeric / NULLIF(sum(drives), 0)                     AS off_three_and_out_rate,
        avg(rush_yards)                                                           AS off_rush_yards_pg,
        avg(pass_yards)                                                           AS off_pass_yards_pg,
        -- defense (what it allowed)
        avg(points_against)                                                       AS def_points_pg,
        sum(opp_total_yards)::numeric / NULLIF(sum(opp_pass_att + opp_rush_att), 0) AS def_yards_per_play,
        sum(def_ppa * def_plays) / NULLIF(sum(def_plays), 0)                      AS def_ppa,
        sum(def_success_rate * def_plays) / NULLIF(sum(def_plays), 0)             AS def_success_rate,
        sum(opp_third_conv)::numeric / NULLIF(sum(opp_third_att), 0)              AS def_third_down_pct,
        sum(points_against)::numeric / NULLIF(sum(opp_drives), 0)                 AS def_points_per_drive,
        sum(opp_three_and_outs)::numeric / NULLIF(sum(opp_drives), 0)             AS def_three_and_out_rate,
        avg(opp_rush_yards)                                                       AS def_rush_yards_pg,
        avg(opp_pass_yards)                                                       AS def_pass_yards_pg
    FROM games
    GROUP BY team
),
long AS (
    -- one row per team per metric
    SELECT s.team, s.games, v.*
    FROM s
    CROSS JOIN LATERAL (VALUES
        (1,  'overall', 'Scoring margin per game',  s.margin_pg,              true),
        (2,  'overall', 'Turnover margin per game', s.turnover_margin_pg,     true),
        (3,  'offense', 'Points per game',          s.off_points_pg,          true),
        (4,  'offense', 'Points per drive',         s.off_points_per_drive,   true),
        (5,  'offense', 'PPA per play',             s.off_ppa,                true),
        (6,  'offense', 'Success rate',             s.off_success_rate,       true),
        (7,  'offense', 'Yards per play',           s.off_yards_per_play,     true),
        (8,  'offense', '3rd down conversion',      s.off_third_down_pct,     true),
        (9,  'offense', 'Three-and-out rate',       s.off_three_and_out_rate, false),
        (10, 'offense', 'Rushing yards per game',   s.off_rush_yards_pg,      true),
        (11, 'offense', 'Passing yards per game',   s.off_pass_yards_pg,      true),
        (3,  'defense', 'Points per game',          s.def_points_pg,          false),
        (4,  'defense', 'Points per drive',         s.def_points_per_drive,   false),
        (5,  'defense', 'PPA per play',             s.def_ppa,                false),
        (6,  'defense', 'Success rate',             s.def_success_rate,       false),
        (7,  'defense', 'Yards per play',           s.def_yards_per_play,     false),
        (8,  'defense', '3rd down conversion',      s.def_third_down_pct,     false),
        (9,  'defense', 'Three-and-out rate',       s.def_three_and_out_rate, true),
        (10, 'defense', 'Rushing yards per game',   s.def_rush_yards_pg,      false),
        (11, 'defense', 'Passing yards per game',   s.def_pass_yards_pg,      false)
    ) AS v(sort, side, metric, value, higher_is_better)
),
ranked AS (
    SELECT long.*,
           CASE WHEN higher_is_better
                THEN rank() OVER (PARTITION BY side, metric ORDER BY value DESC NULLS LAST)
                ELSE rank() OVER (PARTITION BY side, metric ORDER BY value ASC  NULLS LAST)
           END                                                     AS fbs_rank,
           count(*) OVER (PARTITION BY side, metric)               AS fbs_teams
    FROM long
)
SELECT
    t.side,
    t.metric,
    x.team,
    round(t.value, 3)        AS team_value,
    t.fbs_rank               AS team_rank,
    n.opponent,
    round(o.value, 3)        AS opp_value,
    o.fbs_rank               AS opp_rank,
    t.fbs_teams,
    t.higher_is_better
FROM params x
CROSS JOIN next_opp n
JOIN ranked t ON t.team = x.team
LEFT JOIN ranked o ON o.team = n.opponent AND o.side = t.side AND o.metric = t.metric
ORDER BY CASE t.side WHEN 'overall' THEN 1 WHEN 'offense' THEN 2 ELSE 3 END, t.sort;
