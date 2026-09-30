-- =====================================================
-- CORE LAYER: typed, keyed tables built from raw
-- Safe to re-run (drops and rebuilds core.*)
-- =====================================================
CREATE SCHEMA IF NOT EXISTS core;

DROP VIEW  IF EXISTS core.team_games;
DROP TABLE IF EXISTS core.games;

-- Safe casters: return NULL instead of erroring on junk like '--'
CREATE OR REPLACE FUNCTION core.to_int(t text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN btrim(t) ~ '^-?\d+$' THEN btrim(t)::integer END
$$;

CREATE OR REPLACE FUNCTION core.to_seconds(t text) RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN btrim(t) ~ '^\d+:\d{2}$'
            THEN split_part(btrim(t), ':', 1)::int * 60 + split_part(btrim(t), ':', 2)::int
        WHEN btrim(t) ~ '^\d+(\.\d+)?$'
            THEN round(btrim(t)::numeric)::int
    END
$$;

CREATE TABLE core.games AS
SELECT
    core.to_int(season)                                   AS season,
    core.to_int(week)                                     AS week,
    CASE WHEN btrim("date") ~ '^\d{4}-\d{2}-\d{2}$'
         THEN btrim("date")::date END                     AS game_date,
    CASE WHEN btrim(time_et) ~ '^\d{1,2}:\d{2} [AP]M$'
         THEN to_timestamp(btrim(time_et), 'HH12:MI AM')::time END AS kickoff_et,
    NULLIF(btrim(game_type), '')                          AS game_type,
    btrim(away)                                           AS away_team,
    btrim(home)                                           AS home_team,
    core.to_int(rank_away)                                AS rank_away,
    core.to_int(rank_home)                                AS rank_home,
    NULLIF(btrim(conf_away), '')                          AS conf_away,
    NULLIF(btrim(conf_home), '')                          AS conf_home,
    (lower(btrim(neutral)) = 'true')                      AS is_neutral,

    core.to_int(score_away) AS score_away,
    core.to_int(score_home) AS score_home,
    core.to_int(q1_away) AS q1_away, core.to_int(q2_away) AS q2_away,
    core.to_int(q3_away) AS q3_away, core.to_int(q4_away) AS q4_away,
    core.to_int(ot_away) AS ot_away,
    core.to_int(q1_home) AS q1_home, core.to_int(q2_home) AS q2_home,
    core.to_int(q3_home) AS q3_home, core.to_int(q4_home) AS q4_home,
    core.to_int(ot_home) AS ot_home,

    core.to_int(first_downs_away)      AS first_downs_away,
    core.to_int(first_downs_home)      AS first_downs_home,
    core.to_int(third_down_comp_away)  AS third_down_comp_away,
    core.to_int(third_down_att_away)   AS third_down_att_away,
    core.to_int(third_down_comp_home)  AS third_down_comp_home,
    core.to_int(third_down_att_home)   AS third_down_att_home,
    core.to_int(fourth_down_comp_away) AS fourth_down_comp_away,
    core.to_int(fourth_down_att_away)  AS fourth_down_att_away,
    core.to_int(fourth_down_comp_home) AS fourth_down_comp_home,
    core.to_int(fourth_down_att_home)  AS fourth_down_att_home,
    core.to_int(pass_comp_away)  AS pass_comp_away,
    core.to_int(pass_att_away)   AS pass_att_away,
    core.to_int(pass_comp_home)  AS pass_comp_home,
    core.to_int(pass_att_home)   AS pass_att_home,
    core.to_int(pass_yards_away) AS pass_yards_away,
    core.to_int(pass_yards_home) AS pass_yards_home,
    core.to_int(rush_att_away)   AS rush_att_away,
    core.to_int(rush_yards_away) AS rush_yards_away,
    core.to_int(rush_att_home)   AS rush_att_home,
    core.to_int(rush_yards_home) AS rush_yards_home,
    core.to_int(total_yards_away) AS total_yards_away,
    core.to_int(total_yards_home) AS total_yards_home,
    core.to_int(fum_away) AS fum_away,
    core.to_int(fum_home) AS fum_home,
    core.to_int(int_away) AS int_away,
    core.to_int(int_home) AS int_home,
    core.to_int(pen_num_away)   AS pen_num_away,
    core.to_int(pen_yards_away) AS pen_yards_away,
    core.to_int(pen_num_home)   AS pen_num_home,
    core.to_int(pen_yards_home) AS pen_yards_home,
    core.to_seconds(possession_away) AS possession_away_sec,
    core.to_seconds(possession_home) AS possession_home_sec,
    core.to_int(attendance)          AS attendance,
    NULLIF(btrim(tv), '')            AS tv,

    (core.to_int(pass_yards_home) IS NOT NULL
     AND core.to_int(pass_yards_away) IS NOT NULL) AS has_stats
FROM raw.cfb_games
WHERE core.to_int(season) >= 2004          -- drops 2002 and 2003
ORDER BY 2, 3, 1;                          -- stable id order: week, date

-- Surrogate primary key + natural key constraint
ALTER TABLE core.games ADD COLUMN game_id integer GENERATED ALWAYS AS IDENTITY;
ALTER TABLE core.games ADD PRIMARY KEY (game_id);
ALTER TABLE core.games
    ADD CONSTRAINT uq_games_natural UNIQUE (game_date, away_team, home_team);

CREATE INDEX ix_games_season ON core.games (season);
CREATE INDEX ix_games_home   ON core.games (home_team, season);
CREATE INDEX ix_games_away   ON core.games (away_team, season);
CREATE INDEX ix_games_conf   ON core.games (conf_home, conf_away);

-- =====================================================
-- One row per team per game (best for dashboards + ML)
-- =====================================================
CREATE VIEW core.team_games AS
SELECT
    game_id, season, week, game_date, game_type, has_stats,
    home_team AS team,   away_team AS opponent,
    conf_home AS conf,   conf_away AS opp_conf,
    rank_home AS rank,   rank_away AS opp_rank,
    CASE WHEN is_neutral THEN 'neutral' ELSE 'home' END AS location,
    score_home AS points_for,  score_away AS points_against,
    score_home - score_away    AS margin,
    (score_home > score_away)  AS win,
    first_downs_home AS first_downs,   first_downs_away AS opp_first_downs,
    pass_comp_home   AS pass_comp,     pass_att_home    AS pass_att,
    pass_yards_home  AS pass_yards,    pass_yards_away  AS opp_pass_yards,
    rush_att_home    AS rush_att,      rush_yards_home  AS rush_yards,
    rush_yards_away  AS opp_rush_yards,
    total_yards_home AS total_yards,   total_yards_away AS opp_total_yards,
    fum_home AS fumbles, int_home AS interceptions,
    fum_away AS opp_fumbles, int_away AS opp_interceptions,
    pen_num_home AS penalties, pen_yards_home AS penalty_yards,
    possession_home_sec AS possession_sec,
    attendance
FROM core.games
UNION ALL
SELECT
    game_id, season, week, game_date, game_type, has_stats,
    away_team, home_team,
    conf_away, conf_home,
    rank_away, rank_home,
    CASE WHEN is_neutral THEN 'neutral' ELSE 'away' END,
    score_away, score_home,
    score_away - score_home,
    (score_away > score_home),
    first_downs_away, first_downs_home,
    pass_comp_away, pass_att_away,
    pass_yards_away, pass_yards_home,
    rush_att_away, rush_yards_away,
    rush_yards_home,
    total_yards_away, total_yards_home,
    fum_away, int_away,
    fum_home, int_home,
    pen_num_away, pen_yards_away,
    possession_away_sec,
    attendance
FROM core.games;