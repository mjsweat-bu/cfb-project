-- =====================================================
-- marts.player_career_stats: one row per player, career totals
-- Aggregates marts.player_season_stats. The CFBD API has no career endpoint.
-- Player IDs need two fixes before aggregating:
--   1. Split: the API occasionally reuses one ID for a different, later player
--      (e.g. ID 189239 = a 2006-10 Illinois WR and a 2016-18 WR). A gap of 4+
--      seasons within an ID starts a new segment. (A 2-year LDS mission is a
--      3-season gap, so it stays together.)
--   2. Merge: a transfer sometimes gets a new ID (e.g. Bo Nix at Auburn vs
--      Oregon). Segments are merged when name + hometown match, their seasons
--      don't overlap, and the combined span is at most 7 seasons.
-- player_id is the earliest API ID (suffixed -2, -3 for a split segment);
-- player_ids lists every API ID that went into a row.
-- Caveats: careers are only as complete as the API's season coverage
-- (thin before 2009, no usage/PPA before 2013), and 2026 is in progress.
-- Build 11_player_season_stats.sql first. Safe to re-run.
-- =====================================================
DROP TABLE IF EXISTS marts.player_career_stats;

CREATE TABLE marts.player_career_stats AS
WITH gaps AS (
    SELECT s.*,
           CASE WHEN season - lag(season) OVER (PARTITION BY player_id ORDER BY season, team) >= 4
                THEN 1 ELSE 0 END AS new_seg
    FROM marts.player_season_stats s
),
seg AS (
    SELECT g.*,
           sum(new_seg) OVER (PARTITION BY player_id ORDER BY season, team) AS seg_no
    FROM gaps g
),
segs AS (
    SELECT player_id, seg_no,
           CASE WHEN seg_no = 0 THEN player_id
                ELSE player_id || '-' || (seg_no + 1) END  AS seg_id,
           min(season) AS first_season,
           max(season) AS last_season,
           (array_agg(player     ORDER BY season DESC))[1] AS player,
           (array_agg(home_city  ORDER BY season DESC))[1] AS home_city,
           (array_agg(home_state ORDER BY season DESC))[1] AS home_state
    FROM seg
    GROUP BY player_id, seg_no
),
segs_ordered AS (
    SELECT *,
           -- latest season of any earlier segment with the same name + hometown
           max(last_season) OVER (
               PARTITION BY player, home_city, home_state ORDER BY first_season, seg_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_last_season,
           first_value(seg_id) OVER (
               PARTITION BY player, home_city, home_state ORDER BY first_season, seg_id) AS first_seg_id
    FROM segs
),
id_map AS (
    SELECT player_id, seg_no,
           CASE WHEN home_city IS NOT NULL
                 AND NOT bool_or(first_season <= coalesce(prev_last_season, 0))
                     OVER (PARTITION BY player, home_city, home_state)
                 AND max(last_season)  OVER (PARTITION BY player, home_city, home_state)
                   - min(first_season) OVER (PARTITION BY player, home_city, home_state) <= 6
                THEN first_seg_id ELSE seg_id END AS career_id
    FROM segs_ordered
),
seasons AS (
    SELECT m.career_id, s.*
    FROM seg s
    JOIN id_map m USING (player_id, seg_no)
),
latest AS (
    -- most recent season's row supplies name, position, bio
    SELECT DISTINCT ON (career_id) *
    FROM seasons
    ORDER BY career_id, season DESC, (usage_overall IS NULL), team
),
career AS (
    SELECT
        career_id,
        string_agg(DISTINCT player_id, ', ')           AS player_ids,
        min(season)                                    AS first_season,
        max(season)                                    AS last_season,
        count(DISTINCT season)                         AS seasons,
        string_agg(DISTINCT team, ', ')                AS teams,
        count(DISTINCT team)                           AS num_teams,

        -- passing
        sum(pass_comp)          AS pass_comp,
        sum(pass_att)           AS pass_att,
        sum(pass_yards)         AS pass_yards,
        sum(pass_tds)           AS pass_tds,
        sum(pass_ints)          AS pass_ints,

        -- rushing
        sum(rush_att)           AS rush_att,
        sum(rush_yards)         AS rush_yards,
        sum(rush_tds)           AS rush_tds,
        max(rush_long)          AS rush_long,

        -- receiving
        sum(receptions)         AS receptions,
        sum(rec_yards)          AS rec_yards,
        sum(rec_tds)            AS rec_tds,
        max(rec_long)           AS rec_long,

        -- fumbles
        sum(fumbles)            AS fumbles,
        sum(fumbles_lost)       AS fumbles_lost,
        sum(fumbles_recovered)  AS fumbles_recovered,

        -- defense
        sum(tackles)            AS tackles,
        sum(solo_tackles)       AS solo_tackles,
        sum(tackles_for_loss)   AS tackles_for_loss,
        sum(sacks)              AS sacks,
        sum(qb_hurries)         AS qb_hurries,
        sum(passes_defended)    AS passes_defended,
        sum(def_tds)            AS def_tds,
        sum(def_ints)           AS def_ints,
        sum(int_return_yards)   AS int_return_yards,
        sum(int_return_tds)     AS int_return_tds,

        -- kicking / punting
        sum(fg_made)            AS fg_made,
        sum(fg_att)             AS fg_att,
        max(fg_long)            AS fg_long,
        sum(xp_made)            AS xp_made,
        sum(xp_att)             AS xp_att,
        sum(kick_points)        AS kick_points,
        sum(punts)              AS punts,
        sum(punt_yards)         AS punt_yards,
        sum(punts_inside_20)    AS punts_inside_20,
        sum(punt_touchbacks)    AS punt_touchbacks,
        max(punt_long)          AS punt_long,

        -- returns
        sum(kick_returns)       AS kick_returns,
        sum(kick_return_yards)  AS kick_return_yards,
        sum(kick_return_tds)    AS kick_return_tds,
        sum(punt_returns)       AS punt_returns,
        sum(punt_return_yards)  AS punt_return_yards,
        sum(punt_return_tds)    AS punt_return_tds,

        -- PPA (2013+); per-play averages can't be summed, so only totals
        count(ppa_total)        AS seasons_with_ppa,
        sum(ppa_total)          AS ppa_total,
        sum(ppa_total_pass)     AS ppa_total_pass,
        sum(ppa_total_rush)     AS ppa_total_rush,
        max(ppa_avg)            AS best_season_ppa_avg
    FROM seasons
    GROUP BY career_id
)
SELECT
    c.career_id                                        AS player_id,
    c.player_ids,
    l.player,
    l.position,
    l.team                                             AS last_team,
    c.teams,
    c.num_teams,
    c.first_season,
    c.last_season,
    c.seasons,
    l.class_year                                       AS last_class_year,
    l.height_in,
    l.weight_lb,
    l.home_city,
    l.home_state,
    l.home_country,

    c.pass_comp, c.pass_att, c.pass_yards, c.pass_tds, c.pass_ints,
    round(c.pass_comp::numeric  / NULLIF(c.pass_att, 0), 3)   AS pass_pct,
    round(c.pass_yards::numeric / NULLIF(c.pass_att, 0), 1)   AS pass_ypa,

    c.rush_att, c.rush_yards, c.rush_tds, c.rush_long,
    round(c.rush_yards::numeric / NULLIF(c.rush_att, 0), 1)   AS rush_ypc,

    c.receptions, c.rec_yards, c.rec_tds, c.rec_long,
    round(c.rec_yards::numeric / NULLIF(c.receptions, 0), 1)  AS rec_ypr,

    CASE WHEN c.rush_yards IS NOT NULL OR c.rec_yards IS NOT NULL
         THEN coalesce(c.rush_yards, 0) + coalesce(c.rec_yards, 0) END AS scrimmage_yards,
    CASE WHEN c.rush_tds IS NOT NULL OR c.rec_tds IS NOT NULL
         THEN coalesce(c.rush_tds, 0) + coalesce(c.rec_tds, 0) END     AS scrimmage_tds,

    c.fumbles, c.fumbles_lost, c.fumbles_recovered,

    c.tackles, c.solo_tackles, c.tackles_for_loss, c.sacks, c.qb_hurries,
    c.passes_defended, c.def_tds, c.def_ints, c.int_return_yards, c.int_return_tds,

    c.fg_made, c.fg_att,
    round(c.fg_made::numeric / NULLIF(c.fg_att, 0), 3)         AS fg_pct,
    c.fg_long, c.xp_made, c.xp_att, c.kick_points,
    c.punts, c.punt_yards,
    round(c.punt_yards::numeric / NULLIF(c.punts, 0), 1)       AS punt_avg,
    c.punts_inside_20, c.punt_touchbacks, c.punt_long,

    c.kick_returns, c.kick_return_yards, c.kick_return_tds,
    c.punt_returns, c.punt_return_yards, c.punt_return_tds,

    c.seasons_with_ppa, c.ppa_total, c.ppa_total_pass, c.ppa_total_rush,
    c.best_season_ppa_avg
FROM career c
JOIN latest l USING (career_id);

ALTER TABLE marts.player_career_stats ADD PRIMARY KEY (player_id);
CREATE INDEX ix_player_career_stats_team ON marts.player_career_stats (last_team);
