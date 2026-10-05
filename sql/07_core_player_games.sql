-- =====================================================
-- core.player_games: one row per player per game (FBS games), from raw.api_game_players
-- Load raw data first:  python src\ingest_api.py game_players 2004 2015
-- Currently loaded for 2004-2015, where /stats/player/season is missing many
-- players (e.g. Cam Newton 2010). 11_player_season_stats.sql uses this table
-- to fill those gaps, so build this before 11.
-- Needs core.to_int / core.to_num (01_functions.sql).
-- Safe to re-run.
-- =====================================================
CREATE SCHEMA IF NOT EXISTS core;

CREATE OR REPLACE FUNCTION core.to_num(t text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN btrim(t) ~ '^-?\d+(\.\d+)?$' THEN btrim(t)::numeric END
$$;

DROP TABLE IF EXISTS core.player_games;

CREATE TABLE core.player_games AS
WITH teams AS (
    SELECT g.game_id, g.season, g.season_type, g.week, t.value AS t,
           -- the other team in the game
           (SELECT o->>'team' FROM jsonb_array_elements(g.payload->'teams') o
            WHERE o->>'team' IS DISTINCT FROM t.value->>'team' LIMIT 1) AS opponent
    FROM raw.api_game_players g
    CROSS JOIN jsonb_array_elements(g.payload->'teams') t
),
flat AS (
    -- one row per (game, player, stat)
    SELECT tm.game_id, tm.season, tm.season_type, tm.week,
           tm.t->>'team'        AS team,
           tm.t->>'conference'  AS conf,
           tm.t->>'homeAway'    AS home_away,
           tm.opponent,
           a->>'id'             AS player_id,
           a->>'name'           AS player,
           c->>'name' || '.' || (ty->>'name') AS stat_key,
           a->>'stat'           AS stat
    FROM teams tm
    CROSS JOIN jsonb_array_elements(tm.t->'categories') c
    CROSS JOIN jsonb_array_elements(c->'types') ty
    CROSS JOIN jsonb_array_elements(ty->'athletes') a
),
p AS (
    SELECT game_id, season, season_type, week, team, conf, home_away, opponent, player_id,
           max(player)                         AS player,
           jsonb_object_agg(stat_key, stat)    AS s
    FROM flat
    GROUP BY game_id, season, season_type, week, team, conf, home_away, opponent, player_id
)
SELECT
    game_id, season, season_type, week, team, conf, home_away, opponent, player_id, player,

    -- passing ("C/ATT" comes as e.g. "15/21")
    core.to_int(split_part(s->>'passing.C/ATT', '/', 1))  AS pass_comp,
    core.to_int(split_part(s->>'passing.C/ATT', '/', 2))  AS pass_att,
    core.to_int(s->>'passing.YDS')                        AS pass_yards,
    core.to_int(s->>'passing.TD')                         AS pass_tds,
    core.to_int(s->>'passing.INT')                        AS pass_ints,
    core.to_num(s->>'passing.QBR')                        AS qbr,

    -- rushing
    core.to_int(s->>'rushing.CAR')                        AS rush_att,
    core.to_int(s->>'rushing.YDS')                        AS rush_yards,
    core.to_int(s->>'rushing.TD')                         AS rush_tds,
    core.to_int(s->>'rushing.LONG')                       AS rush_long,

    -- receiving
    core.to_int(s->>'receiving.REC')                      AS receptions,
    core.to_int(s->>'receiving.YDS')                      AS rec_yards,
    core.to_int(s->>'receiving.TD')                       AS rec_tds,
    core.to_int(s->>'receiving.LONG')                     AS rec_long,

    -- fumbles
    core.to_int(s->>'fumbles.FUM')                        AS fumbles,
    core.to_int(s->>'fumbles.LOST')                       AS fumbles_lost,
    core.to_int(s->>'fumbles.REC')                        AS fumbles_recovered,

    -- defense
    core.to_int(s->>'defensive.TOT')                      AS tackles,
    core.to_int(s->>'defensive.SOLO')                     AS solo_tackles,
    core.to_num(s->>'defensive.TFL')                      AS tackles_for_loss,
    core.to_num(s->>'defensive.SACKS')                    AS sacks,
    core.to_int(s->>'defensive.QB HUR')                   AS qb_hurries,
    core.to_int(s->>'defensive.PD')                       AS passes_defended,
    core.to_int(s->>'defensive.TD')                       AS def_tds,
    core.to_int(s->>'interceptions.INT')                  AS def_ints,
    core.to_int(s->>'interceptions.YDS')                  AS int_return_yards,
    core.to_int(s->>'interceptions.TD')                   AS int_return_tds,

    -- kicking ("FG" and "XP" come as made/attempted)
    core.to_int(split_part(s->>'kicking.FG', '/', 1))     AS fg_made,
    core.to_int(split_part(s->>'kicking.FG', '/', 2))     AS fg_att,
    core.to_int(s->>'kicking.LONG')                       AS fg_long,
    core.to_int(split_part(s->>'kicking.XP', '/', 1))     AS xp_made,
    core.to_int(split_part(s->>'kicking.XP', '/', 2))     AS xp_att,
    core.to_int(s->>'kicking.PTS')                        AS kick_points,

    -- punting
    core.to_int(s->>'punting.NO')                         AS punts,
    core.to_int(s->>'punting.YDS')                        AS punt_yards,
    core.to_int(s->>'punting.In 20')                      AS punts_inside_20,
    core.to_int(s->>'punting.TB')                         AS punt_touchbacks,
    core.to_int(s->>'punting.LONG')                       AS punt_long,

    -- returns
    core.to_int(s->>'kickReturns.NO')                     AS kick_returns,
    core.to_int(s->>'kickReturns.YDS')                    AS kick_return_yards,
    core.to_int(s->>'kickReturns.TD')                     AS kick_return_tds,
    core.to_int(s->>'puntReturns.NO')                     AS punt_returns,
    core.to_int(s->>'puntReturns.YDS')                    AS punt_return_yards,
    core.to_int(s->>'puntReturns.TD')                     AS punt_return_tds
FROM p;

ALTER TABLE core.player_games ADD PRIMARY KEY (game_id, player_id, team);
CREATE INDEX ix_player_games_player ON core.player_games (player_id, season);
CREATE INDEX ix_player_games_team   ON core.player_games (season, team);

-- refresh planner statistics so queries right after a rebuild get a good plan
ANALYZE core.player_games;
