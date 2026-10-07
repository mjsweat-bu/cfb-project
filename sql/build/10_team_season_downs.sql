-- =====================================================
-- marts.team_season_downs: one row per FBS team per season (2016+)
-- Per-down offense and defense from core.plays, scrimmage plays only
-- (penalties, kicks and 2-pt tries excluded; sacks count as pass plays;
-- interceptions count as 0 yards). Includes postseason and garbage time.
--   off_* = the team's offense, def_* = what its defense allowed
--   d1..d4 = 1st..4th down
--   *_success_rate: gain >= 50% of distance on 1st, 70% on 2nd, 100% on 3rd/4th
-- Build 09_team_season_stats.sql (FBS team list) and 04_core_plays.sql first.
-- Safe to re-run.
-- =====================================================
DROP TABLE IF EXISTS marts.team_season_downs;

CREATE TABLE marts.team_season_downs AS
WITH scrim AS (
    SELECT * FROM core.plays WHERE is_scrimmage
),
off AS (
    SELECT season, offense AS team,
    count(DISTINCT game_id)                               AS games,
    count(*)                                              AS off_plays,
    round(avg(off_yards), 2)                              AS off_yards_per_play,
    round(avg(is_success::int), 3)                        AS off_success_rate,
    round(avg((off_yards >= distance)::int) FILTER (WHERE down = 3), 3) AS off_d3_conversion_rate,
    round(avg((off_yards >= distance)::int) FILTER (WHERE down = 4), 3) AS off_d4_conversion_rate,
    -- 1st down
    count(*) FILTER (WHERE down = 1)               AS off_d1_plays,
    round(avg(off_yards) FILTER (WHERE down = 1), 2) AS off_d1_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 1 AND play_category = 'rush'), 2) AS off_d1_rush_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 1 AND play_category = 'pass'), 2) AS off_d1_pass_yards_per_play,
    round(avg((play_category = 'pass')::int) FILTER (WHERE down = 1), 3)    AS off_d1_pass_rate,
    round(avg(distance) FILTER (WHERE down = 1), 2)  AS off_d1_avg_distance,
    round(avg(is_success::int) FILTER (WHERE down = 1), 3) AS off_d1_success_rate,
    round(avg(ppa) FILTER (WHERE down = 1), 3)       AS off_d1_ppa,
    -- 2nd down
    count(*) FILTER (WHERE down = 2)               AS off_d2_plays,
    round(avg(off_yards) FILTER (WHERE down = 2), 2) AS off_d2_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 2 AND play_category = 'rush'), 2) AS off_d2_rush_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 2 AND play_category = 'pass'), 2) AS off_d2_pass_yards_per_play,
    round(avg((play_category = 'pass')::int) FILTER (WHERE down = 2), 3)    AS off_d2_pass_rate,
    round(avg(distance) FILTER (WHERE down = 2), 2)  AS off_d2_avg_distance,
    round(avg(is_success::int) FILTER (WHERE down = 2), 3) AS off_d2_success_rate,
    round(avg(ppa) FILTER (WHERE down = 2), 3)       AS off_d2_ppa,
    -- 3rd down
    count(*) FILTER (WHERE down = 3)               AS off_d3_plays,
    round(avg(off_yards) FILTER (WHERE down = 3), 2) AS off_d3_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 3 AND play_category = 'rush'), 2) AS off_d3_rush_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 3 AND play_category = 'pass'), 2) AS off_d3_pass_yards_per_play,
    round(avg((play_category = 'pass')::int) FILTER (WHERE down = 3), 3)    AS off_d3_pass_rate,
    round(avg(distance) FILTER (WHERE down = 3), 2)  AS off_d3_avg_distance,
    round(avg(is_success::int) FILTER (WHERE down = 3), 3) AS off_d3_success_rate,
    round(avg(ppa) FILTER (WHERE down = 3), 3)       AS off_d3_ppa,
    -- 4th down
    count(*) FILTER (WHERE down = 4)               AS off_d4_plays,
    round(avg(off_yards) FILTER (WHERE down = 4), 2) AS off_d4_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 4 AND play_category = 'rush'), 2) AS off_d4_rush_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 4 AND play_category = 'pass'), 2) AS off_d4_pass_yards_per_play,
    round(avg((play_category = 'pass')::int) FILTER (WHERE down = 4), 3)    AS off_d4_pass_rate,
    round(avg(distance) FILTER (WHERE down = 4), 2)  AS off_d4_avg_distance,
    round(avg(is_success::int) FILTER (WHERE down = 4), 3) AS off_d4_success_rate,
    round(avg(ppa) FILTER (WHERE down = 4), 3)       AS off_d4_ppa
    FROM scrim
    GROUP BY season, offense
),
def AS (
    SELECT season, defense AS team,
    count(*)                                              AS def_plays,
    round(avg(off_yards), 2)                              AS def_yards_per_play,
    round(avg(is_success::int), 3)                        AS def_success_rate,
    round(avg((off_yards >= distance)::int) FILTER (WHERE down = 3), 3) AS def_d3_conversion_rate,
    round(avg((off_yards >= distance)::int) FILTER (WHERE down = 4), 3) AS def_d4_conversion_rate,
    -- 1st down
    count(*) FILTER (WHERE down = 1)               AS def_d1_plays,
    round(avg(off_yards) FILTER (WHERE down = 1), 2) AS def_d1_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 1 AND play_category = 'rush'), 2) AS def_d1_rush_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 1 AND play_category = 'pass'), 2) AS def_d1_pass_yards_per_play,
    round(avg((play_category = 'pass')::int) FILTER (WHERE down = 1), 3)    AS def_d1_pass_rate,
    round(avg(distance) FILTER (WHERE down = 1), 2)  AS def_d1_avg_distance,
    round(avg(is_success::int) FILTER (WHERE down = 1), 3) AS def_d1_success_rate,
    round(avg(ppa) FILTER (WHERE down = 1), 3)       AS def_d1_ppa,
    -- 2nd down
    count(*) FILTER (WHERE down = 2)               AS def_d2_plays,
    round(avg(off_yards) FILTER (WHERE down = 2), 2) AS def_d2_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 2 AND play_category = 'rush'), 2) AS def_d2_rush_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 2 AND play_category = 'pass'), 2) AS def_d2_pass_yards_per_play,
    round(avg((play_category = 'pass')::int) FILTER (WHERE down = 2), 3)    AS def_d2_pass_rate,
    round(avg(distance) FILTER (WHERE down = 2), 2)  AS def_d2_avg_distance,
    round(avg(is_success::int) FILTER (WHERE down = 2), 3) AS def_d2_success_rate,
    round(avg(ppa) FILTER (WHERE down = 2), 3)       AS def_d2_ppa,
    -- 3rd down
    count(*) FILTER (WHERE down = 3)               AS def_d3_plays,
    round(avg(off_yards) FILTER (WHERE down = 3), 2) AS def_d3_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 3 AND play_category = 'rush'), 2) AS def_d3_rush_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 3 AND play_category = 'pass'), 2) AS def_d3_pass_yards_per_play,
    round(avg((play_category = 'pass')::int) FILTER (WHERE down = 3), 3)    AS def_d3_pass_rate,
    round(avg(distance) FILTER (WHERE down = 3), 2)  AS def_d3_avg_distance,
    round(avg(is_success::int) FILTER (WHERE down = 3), 3) AS def_d3_success_rate,
    round(avg(ppa) FILTER (WHERE down = 3), 3)       AS def_d3_ppa,
    -- 4th down
    count(*) FILTER (WHERE down = 4)               AS def_d4_plays,
    round(avg(off_yards) FILTER (WHERE down = 4), 2) AS def_d4_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 4 AND play_category = 'rush'), 2) AS def_d4_rush_yards_per_play,
    round(avg(off_yards) FILTER (WHERE down = 4 AND play_category = 'pass'), 2) AS def_d4_pass_yards_per_play,
    round(avg((play_category = 'pass')::int) FILTER (WHERE down = 4), 3)    AS def_d4_pass_rate,
    round(avg(distance) FILTER (WHERE down = 4), 2)  AS def_d4_avg_distance,
    round(avg(is_success::int) FILTER (WHERE down = 4), 3) AS def_d4_success_rate,
    round(avg(ppa) FILTER (WHERE down = 4), 3)       AS def_d4_ppa
    FROM scrim
    GROUP BY season, defense
)
SELECT
    t.season, t.team, t.conf, o.games,
    o.off_plays, o.off_yards_per_play, o.off_success_rate,
    x.def_plays, x.def_yards_per_play, x.def_success_rate,
    o.off_d3_conversion_rate, o.off_d4_conversion_rate,
    x.def_d3_conversion_rate, x.def_d4_conversion_rate,
    -- 1st down
    o.off_d1_plays, o.off_d1_yards_per_play, o.off_d1_rush_yards_per_play, o.off_d1_pass_yards_per_play, o.off_d1_pass_rate, o.off_d1_avg_distance, o.off_d1_success_rate, o.off_d1_ppa,
    x.def_d1_plays, x.def_d1_yards_per_play, x.def_d1_rush_yards_per_play, x.def_d1_pass_yards_per_play, x.def_d1_pass_rate, x.def_d1_avg_distance, x.def_d1_success_rate, x.def_d1_ppa,
    -- 2nd down
    o.off_d2_plays, o.off_d2_yards_per_play, o.off_d2_rush_yards_per_play, o.off_d2_pass_yards_per_play, o.off_d2_pass_rate, o.off_d2_avg_distance, o.off_d2_success_rate, o.off_d2_ppa,
    x.def_d2_plays, x.def_d2_yards_per_play, x.def_d2_rush_yards_per_play, x.def_d2_pass_yards_per_play, x.def_d2_pass_rate, x.def_d2_avg_distance, x.def_d2_success_rate, x.def_d2_ppa,
    -- 3rd down
    o.off_d3_plays, o.off_d3_yards_per_play, o.off_d3_rush_yards_per_play, o.off_d3_pass_yards_per_play, o.off_d3_pass_rate, o.off_d3_avg_distance, o.off_d3_success_rate, o.off_d3_ppa,
    x.def_d3_plays, x.def_d3_yards_per_play, x.def_d3_rush_yards_per_play, x.def_d3_pass_yards_per_play, x.def_d3_pass_rate, x.def_d3_avg_distance, x.def_d3_success_rate, x.def_d3_ppa,
    -- 4th down
    o.off_d4_plays, o.off_d4_yards_per_play, o.off_d4_rush_yards_per_play, o.off_d4_pass_yards_per_play, o.off_d4_pass_rate, o.off_d4_avg_distance, o.off_d4_success_rate, o.off_d4_ppa,
    x.def_d4_plays, x.def_d4_yards_per_play, x.def_d4_rush_yards_per_play, x.def_d4_pass_yards_per_play, x.def_d4_pass_rate, x.def_d4_avg_distance, x.def_d4_success_rate, x.def_d4_ppa
FROM marts.team_season_stats t
JOIN off o USING (season, team)
JOIN def x USING (season, team);

ALTER TABLE marts.team_season_downs ADD PRIMARY KEY (season, team);
