-- =====================================================
-- marts.player_season_stats: one row per player per team per season, from the CFBD API
-- Same content as /player/season/overview (box score + usage + PPA), built from
-- the bulk endpoints so it takes 4 API calls per season instead of 1 per player:
--   raw.api_player_seasons  stats/player/season -> box score stats (all players)
--                           player/usage        -> usage rates  (offensive players with plays)
--                           ppa/players/season  -> PPA          (offensive players with plays)
--                           roster              -> bio: height, weight, class, hometown
-- Load raw data first:  python src\ingest_api.py player_seasons 2004 2026
-- Needs core.to_int from 02_core.sql. Safe to re-run.
-- =====================================================
CREATE SCHEMA IF NOT EXISTS marts;

-- Safe numeric caster (stats like SACKS, TFL, YPC come as decimal strings)
CREATE OR REPLACE FUNCTION core.to_num(t text) RETURNS numeric
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN btrim(t) ~ '^-?\d+(\.\d+)?$' THEN btrim(t)::numeric END
$$;

DROP TABLE IF EXISTS marts.player_season_stats;

CREATE TABLE marts.player_season_stats AS
WITH src AS (
    SELECT endpoint, season, record_key, payload
    FROM raw.api_player_seasons
),
box AS (
    SELECT season, record_key, payload AS p, payload->'stats' AS st
    FROM src WHERE endpoint = 'stats/player/season'
),
usg AS (SELECT season, record_key, payload->'usage'      AS u  FROM src WHERE endpoint = 'player/usage'),
ppa AS (SELECT season, record_key, payload->'averagePPA' AS pa,
                                   payload->'totalPPA'   AS pt FROM src WHERE endpoint = 'ppa/players/season'),
ros AS (SELECT season, record_key, payload               AS r  FROM src WHERE endpoint = 'roster')
SELECT
    b.season,
    p->>'playerId'                                     AS player_id,
    p->>'player'                                       AS player,
    p->>'position'                                     AS position,
    p->>'team'                                         AS team,
    p->>'conference'                                   AS conf,

    -- ---------- bio (roster) ----------
    r->>'firstName'                                    AS first_name,
    r->>'lastName'                                     AS last_name,
    (r->>'jersey')::int                                AS jersey,
    (r->>'height')::numeric                            AS height_in,
    (r->>'weight')::int                                AS weight_lb,
    CASE WHEN (r->>'year')::int BETWEEN 1 AND 5
         THEN (r->>'year')::int END                    AS class_year,   -- 1=FR .. 4=SR
    r->>'homeCity'                                     AS home_city,
    r->>'homeState'                                    AS home_state,
    r->>'homeCountry'                                  AS home_country,

    -- ---------- passing ----------
    core.to_int(st->'passing'->>'COMPLETIONS')         AS pass_comp,
    core.to_int(st->'passing'->>'ATT')                 AS pass_att,
    core.to_int(st->'passing'->>'YDS')                 AS pass_yards,
    core.to_int(st->'passing'->>'TD')                  AS pass_tds,
    core.to_int(st->'passing'->>'INT')                 AS pass_ints,
    core.to_num(st->'passing'->>'PCT')                 AS pass_pct,
    core.to_num(st->'passing'->>'YPA')                 AS pass_ypa,

    -- ---------- rushing ----------
    core.to_int(st->'rushing'->>'CAR')                 AS rush_att,
    core.to_int(st->'rushing'->>'YDS')                 AS rush_yards,
    core.to_int(st->'rushing'->>'TD')                  AS rush_tds,
    core.to_int(st->'rushing'->>'LONG')                AS rush_long,
    core.to_num(st->'rushing'->>'YPC')                 AS rush_ypc,

    -- ---------- receiving ----------
    core.to_int(st->'receiving'->>'REC')               AS receptions,
    core.to_int(st->'receiving'->>'YDS')               AS rec_yards,
    core.to_int(st->'receiving'->>'TD')                AS rec_tds,
    core.to_int(st->'receiving'->>'LONG')              AS rec_long,
    core.to_num(st->'receiving'->>'YPR')               AS rec_ypr,

    -- ---------- fumbles ----------
    core.to_int(st->'fumbles'->>'FUM')                 AS fumbles,
    core.to_int(st->'fumbles'->>'LOST')                AS fumbles_lost,
    core.to_int(st->'fumbles'->>'REC')                 AS fumbles_recovered,

    -- ---------- defense ----------
    core.to_int(st->'defensive'->>'TOT')               AS tackles,
    core.to_int(st->'defensive'->>'SOLO')              AS solo_tackles,
    core.to_num(st->'defensive'->>'TFL')               AS tackles_for_loss,
    core.to_num(st->'defensive'->>'SACKS')             AS sacks,
    core.to_int(st->'defensive'->>'QB HUR')            AS qb_hurries,
    core.to_int(st->'defensive'->>'PD')                AS passes_defended,
    core.to_int(st->'defensive'->>'TD')                AS def_tds,
    core.to_int(st->'interceptions'->>'INT')           AS def_ints,
    core.to_int(st->'interceptions'->>'YDS')           AS int_return_yards,
    core.to_int(st->'interceptions'->>'TD')            AS int_return_tds,

    -- ---------- kicking / punting ----------
    core.to_int(st->'kicking'->>'FGM')                 AS fg_made,
    core.to_int(st->'kicking'->>'FGA')                 AS fg_att,
    core.to_int(st->'kicking'->>'LONG')                AS fg_long,
    core.to_int(st->'kicking'->>'XPM')                 AS xp_made,
    core.to_int(st->'kicking'->>'XPA')                 AS xp_att,
    core.to_int(st->'kicking'->>'PTS')                 AS kick_points,
    core.to_int(st->'punting'->>'NO')                  AS punts,
    core.to_int(st->'punting'->>'YDS')                 AS punt_yards,
    core.to_num(st->'punting'->>'YPP')                 AS punt_avg,
    core.to_int(st->'punting'->>'In 20')               AS punts_inside_20,
    core.to_int(st->'punting'->>'TB')                  AS punt_touchbacks,
    core.to_int(st->'punting'->>'LONG')                AS punt_long,

    -- ---------- returns ----------
    core.to_int(st->'kickReturns'->>'NO')              AS kick_returns,
    core.to_int(st->'kickReturns'->>'YDS')             AS kick_return_yards,
    core.to_int(st->'kickReturns'->>'TD')              AS kick_return_tds,
    core.to_int(st->'puntReturns'->>'NO')              AS punt_returns,
    core.to_int(st->'puntReturns'->>'YDS')             AS punt_return_yards,
    core.to_int(st->'puntReturns'->>'TD')              AS punt_return_tds,

    -- ---------- usage: share of team plays involving the player ----------
    (u->>'overall')::numeric                           AS usage_overall,
    (u->>'pass')::numeric                              AS usage_pass,
    (u->>'rush')::numeric                              AS usage_rush,
    (u->>'firstDown')::numeric                         AS usage_first_down,
    (u->>'secondDown')::numeric                        AS usage_second_down,
    (u->>'thirdDown')::numeric                         AS usage_third_down,
    (u->>'standardDowns')::numeric                     AS usage_standard_downs,
    (u->>'passingDowns')::numeric                      AS usage_passing_downs,

    -- ---------- PPA (predicted points added) per play ----------
    (pa->>'all')::numeric                              AS ppa_avg,
    (pa->>'pass')::numeric                             AS ppa_avg_pass,
    (pa->>'rush')::numeric                             AS ppa_avg_rush,
    (pa->>'firstDown')::numeric                        AS ppa_avg_first_down,
    (pa->>'secondDown')::numeric                       AS ppa_avg_second_down,
    (pa->>'thirdDown')::numeric                        AS ppa_avg_third_down,
    (pa->>'standardDowns')::numeric                    AS ppa_avg_standard_downs,
    (pa->>'passingDowns')::numeric                     AS ppa_avg_passing_downs,

    -- ---------- PPA season totals ----------
    (pt->>'all')::numeric                              AS ppa_total,
    (pt->>'pass')::numeric                             AS ppa_total_pass,
    (pt->>'rush')::numeric                             AS ppa_total_rush,
    (pt->>'firstDown')::numeric                        AS ppa_total_first_down,
    (pt->>'secondDown')::numeric                       AS ppa_total_second_down,
    (pt->>'thirdDown')::numeric                        AS ppa_total_third_down,
    (pt->>'standardDowns')::numeric                    AS ppa_total_standard_downs,
    (pt->>'passingDowns')::numeric                     AS ppa_total_passing_downs
FROM box b
LEFT JOIN usg USING (season, record_key)
LEFT JOIN ppa USING (season, record_key)
LEFT JOIN ros USING (season, record_key);

ALTER TABLE marts.player_season_stats ADD PRIMARY KEY (season, player_id, team);
CREATE INDEX ix_player_season_stats_team   ON marts.player_season_stats (season, team);
CREATE INDEX ix_player_season_stats_player ON marts.player_season_stats (player_id);
