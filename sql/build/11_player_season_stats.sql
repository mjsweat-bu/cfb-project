-- =====================================================
-- marts.player_season_stats: one row per player per team per season, from the CFBD API
-- Same content as /player/season/overview (box score + usage + PPA), built from
-- the bulk endpoints so it takes 4 API calls per season instead of 1 per player:
--   raw.api_player_seasons  stats/player/season -> box score stats (all players)
--                           player/usage        -> usage rates  (offensive players with plays)
--                           ppa/players/season  -> PPA          (offensive players with plays)
--                           roster              -> bio: height, weight, class, hometown
--   core.player_games       per-game box scores, summed to the season, fill in
--                           players missing from stats/player/season (common
--                           before 2016, e.g. Cam Newton 2010). FBS teams only.
--                           stats_source says which one a row's box score came from.
-- Load raw data first:  python -m cfb.ingest_api player_seasons 2004 2026
--                       python -m cfb.ingest_api game_players 2004 2015
-- Needs core.to_int / core.to_num (01_functions.sql), marts.team_season_stats (09) and
-- core.player_games (07_core_player_games.sql). Safe to re-run.
-- =====================================================
CREATE SCHEMA IF NOT EXISTS marts;

DROP TABLE IF EXISTS marts.player_season_stats;

CREATE TABLE marts.player_season_stats AS
WITH src AS (
    SELECT endpoint, season, record_key, payload
    FROM raw.api_player_seasons
),
season_box AS (
    SELECT season, record_key, payload AS p, payload->'stats' AS st, 'season' AS stats_source
    FROM src WHERE endpoint = 'stats/player/season'
),
game_box AS (
    -- season totals from per-game box scores, shaped like the stats/player/season payload
    SELECT g.season,
           g.player_id || '|' || g.team AS record_key,
           jsonb_build_object('playerId', g.player_id, 'player', max(g.player),
                              'team', g.team, 'conference', max(g.conf)) AS p,
           jsonb_build_object(
               'passing', jsonb_build_object(
                   'COMPLETIONS', sum(pass_comp), 'ATT', sum(pass_att), 'YDS', sum(pass_yards),
                   'TD', sum(pass_tds), 'INT', sum(pass_ints),
                   'PCT', round(sum(pass_comp)::numeric / NULLIF(sum(pass_att), 0), 3),
                   'YPA', round(sum(pass_yards)::numeric / NULLIF(sum(pass_att), 0), 1)),
               'rushing', jsonb_build_object(
                   'CAR', sum(rush_att), 'YDS', sum(rush_yards), 'TD', sum(rush_tds), 'LONG', max(rush_long),
                   'YPC', round(sum(rush_yards)::numeric / NULLIF(sum(rush_att), 0), 1)),
               'receiving', jsonb_build_object(
                   'REC', sum(receptions), 'YDS', sum(rec_yards), 'TD', sum(rec_tds), 'LONG', max(rec_long),
                   'YPR', round(sum(rec_yards)::numeric / NULLIF(sum(receptions), 0), 1)),
               'fumbles', jsonb_build_object(
                   'FUM', sum(fumbles), 'LOST', sum(fumbles_lost), 'REC', sum(fumbles_recovered)),
               'defensive', jsonb_build_object(
                   'TOT', sum(tackles), 'SOLO', sum(solo_tackles), 'TFL', sum(tackles_for_loss),
                   'SACKS', sum(sacks), 'QB HUR', sum(qb_hurries), 'PD', sum(passes_defended),
                   'TD', sum(def_tds)),
               'interceptions', jsonb_build_object(
                   'INT', sum(def_ints), 'YDS', sum(int_return_yards), 'TD', sum(int_return_tds)),
               'kicking', jsonb_build_object(
                   'FGM', sum(fg_made), 'FGA', sum(fg_att), 'LONG', max(fg_long),
                   'XPM', sum(xp_made), 'XPA', sum(xp_att), 'PTS', sum(kick_points)),
               'punting', jsonb_build_object(
                   'NO', sum(punts), 'YDS', sum(punt_yards), 'In 20', sum(punts_inside_20),
                   'TB', sum(punt_touchbacks), 'LONG', max(punt_long),
                   'YPP', round(sum(punt_yards)::numeric / NULLIF(sum(punts), 0), 1)),
               'kickReturns', jsonb_build_object(
                   'NO', sum(kick_returns), 'YDS', sum(kick_return_yards), 'TD', sum(kick_return_tds)),
               'puntReturns', jsonb_build_object(
                   'NO', sum(punt_returns), 'YDS', sum(punt_return_yards), 'TD', sum(punt_return_tds))
           ) AS st,
           'games' AS stats_source
    FROM core.player_games g
    WHERE EXISTS (SELECT 1 FROM marts.team_season_stats t                        -- FBS teams only
                  WHERE t.season = g.season AND t.team = g.team)
      AND NOT EXISTS (SELECT 1 FROM season_box sb
                      WHERE sb.season = g.season AND sb.record_key = g.player_id || '|' || g.team)
    GROUP BY g.season, g.player_id, g.team
),
box AS (
    SELECT * FROM season_box
    UNION ALL
    SELECT * FROM game_box
),
usg AS (SELECT season, record_key, payload->'usage'      AS u  FROM src WHERE endpoint = 'player/usage'),
ppa AS (SELECT season, record_key, payload->'averagePPA' AS pa,
                                   payload->'totalPPA'   AS pt FROM src WHERE endpoint = 'ppa/players/season'),
ros AS (SELECT season, record_key, payload               AS r  FROM src WHERE endpoint = 'roster')
SELECT
    b.season,
    p->>'playerId'                                     AS player_id,
    p->>'player'                                       AS player,
    coalesce(p->>'position', r->>'position')           AS position,
    p->>'team'                                         AS team,
    p->>'conference'                                   AS conf,
    stats_source,

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
