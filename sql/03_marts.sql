-- =====================================================
-- MARTS LAYER: analysis-ready tables built from core
-- Safe to re-run (drops and rebuilds marts.*)
-- =====================================================
CREATE SCHEMA IF NOT EXISTS marts;

DROP TABLE IF EXISTS marts.team_seasons;

CREATE TABLE marts.team_seasons AS
SELECT
    season,
    team,
    mode() WITHIN GROUP (ORDER BY conf)                    AS conf,

    -- overall record
    count(*)                                               AS games,
    count(*) FILTER (WHERE points_for > points_against)    AS wins,
    count(*) FILTER (WHERE points_for < points_against)    AS losses,
    count(*) FILTER (WHERE points_for = points_against)    AS ties,
    round(avg((points_for > points_against)::int)::numeric, 3) AS win_pct,

    -- conference record (both teams in the same conference)
    count(*) FILTER (WHERE conf IS NOT NULL AND conf = opp_conf)                                   AS conf_games,
    count(*) FILTER (WHERE conf IS NOT NULL AND conf = opp_conf AND points_for > points_against)   AS conf_wins,
    count(*) FILTER (WHERE conf IS NOT NULL AND conf = opp_conf AND points_for < points_against)   AS conf_losses,

    -- home / away / neutral wins and losses
    count(*) FILTER (WHERE location = 'home'    AND points_for > points_against) AS home_wins,
    count(*) FILTER (WHERE location = 'home'    AND points_for < points_against) AS home_losses,
    count(*) FILTER (WHERE location = 'away'    AND points_for > points_against) AS away_wins,
    count(*) FILTER (WHERE location = 'away'    AND points_for < points_against) AS away_losses,
    count(*) FILTER (WHERE location = 'neutral' AND points_for > points_against) AS neutral_wins,
    count(*) FILTER (WHERE location = 'neutral' AND points_for < points_against) AS neutral_losses,

    -- vs ranked opponents
    count(*) FILTER (WHERE opp_rank IS NOT NULL)                                 AS ranked_opp_games,
    count(*) FILTER (WHERE opp_rank IS NOT NULL AND points_for > points_against) AS ranked_opp_wins,

    -- scoring
    sum(points_for)                                        AS points_for,
    sum(points_against)                                    AS points_against,
    round(avg(points_for)::numeric, 1)                     AS ppg,
    round(avg(points_against)::numeric, 1)                 AS opp_ppg,
    round(avg(margin)::numeric, 1)                         AS avg_margin,

    -- box-score averages (only games that have stats)
    count(*) FILTER (WHERE has_stats)                      AS games_with_stats,
    round(avg(total_yards)     FILTER (WHERE has_stats)::numeric, 1) AS yards_pg,
    round(avg(opp_total_yards) FILTER (WHERE has_stats)::numeric, 1) AS opp_yards_pg,
    round(avg(pass_yards)      FILTER (WHERE has_stats)::numeric, 1) AS pass_yards_pg,
    round(avg(rush_yards)      FILTER (WHERE has_stats)::numeric, 1) AS rush_yards_pg,
    round(avg(penalty_yards)   FILTER (WHERE has_stats)::numeric, 1) AS penalty_yards_pg,
    round(avg(possession_sec)  FILTER (WHERE has_stats)::numeric / 60, 1) AS possession_min_pg,
    sum(fumbles + interceptions)          FILTER (WHERE has_stats) AS turnovers,
    sum(opp_fumbles + opp_interceptions)  FILTER (WHERE has_stats) AS takeaways
FROM core.team_games
WHERE points_for IS NOT NULL AND points_against IS NOT NULL
GROUP BY season, team;

ALTER TABLE marts.team_seasons ADD PRIMARY KEY (season, team);
CREATE INDEX ix_team_seasons_conf ON marts.team_seasons (season, conf);