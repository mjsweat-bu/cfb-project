-- =====================================================
-- marts.team_season_stats: one row per FBS team per season, from the CFBD API
--   raw.api_team_seasons  stats/season           -> box-score totals (team + opponent)
--                         stats/season/advanced  -> PPA, success rate, havoc, etc.
--                         records                -> W/L splits, expected wins
--   raw.api_games                                -> points for / against
-- Season stats include postseason games. Current season = season-to-date.
-- Load raw data first:  python -m cfb.ingest_api team_seasons 2004 2026
-- Safe to re-run.
-- =====================================================
CREATE SCHEMA IF NOT EXISTS marts;

DROP TABLE IF EXISTS marts.team_season_stats;

CREATE TABLE marts.team_season_stats AS
WITH basic AS (
    -- API returns one row per (team, stat); pivot to one JSON object per team
    SELECT season,
           payload->>'team'                                    AS team,
           max(payload->>'conference')                         AS conf,
           jsonb_object_agg(payload->>'statName', payload->'statValue') AS s
    FROM raw.api_team_seasons
    WHERE endpoint = 'stats/season'
    GROUP BY season, payload->>'team'
),
adv AS (
    SELECT season, payload->>'team' AS team,
           payload->'offense' AS o, payload->'defense' AS d
    FROM raw.api_team_seasons
    WHERE endpoint = 'stats/season/advanced'
),
rec AS (
    SELECT season, payload->>'team' AS team, payload AS r
    FROM raw.api_team_seasons
    WHERE endpoint = 'records'
),
pts AS (
    SELECT season, team, sum(pf) AS points_for, sum(pa) AS points_against
    FROM (
        SELECT season, payload->>'homeTeam' AS team,
               (payload->>'homePoints')::int AS pf, (payload->>'awayPoints')::int AS pa
        FROM raw.api_games
        UNION ALL
        SELECT season, payload->>'awayTeam',
               (payload->>'awayPoints')::int, (payload->>'homePoints')::int
        FROM raw.api_games
    ) g
    WHERE pf IS NOT NULL AND pa IS NOT NULL
    GROUP BY season, team
)
SELECT
    b.season,
    b.team,
    b.conf,
    (s->>'games')::int                                         AS games,

    -- ---------- record ----------
    (r->'total'->>'wins')::int                                 AS wins,
    (r->'total'->>'losses')::int                               AS losses,
    (r->'total'->>'ties')::int                                 AS ties,
    (r->'conferenceGames'->>'wins')::int                       AS conf_wins,
    (r->'conferenceGames'->>'losses')::int                     AS conf_losses,
    (r->'homeGames'->>'wins')::int                             AS home_wins,
    (r->'homeGames'->>'losses')::int                           AS home_losses,
    (r->'awayGames'->>'wins')::int                             AS away_wins,
    (r->'awayGames'->>'losses')::int                           AS away_losses,
    (r->'neutralSiteGames'->>'wins')::int                      AS neutral_wins,
    (r->'neutralSiteGames'->>'losses')::int                    AS neutral_losses,
    (r->'postseason'->>'wins')::int                            AS postseason_wins,
    (r->'postseason'->>'losses')::int                          AS postseason_losses,
    round((r->>'expectedWins')::numeric, 2)                    AS expected_wins,

    -- ---------- scoring ----------
    p.points_for,
    p.points_against,
    round(p.points_for::numeric     / NULLIF((s->>'games')::int, 0), 1) AS ppg,
    round(p.points_against::numeric / NULLIF((s->>'games')::int, 0), 1) AS opp_ppg,

    -- ---------- offense / opponent totals ----------
    (s->>'totalYards')::int                                    AS total_yards,
    (s->>'totalYardsOpponent')::int                            AS opp_total_yards,
    round((s->>'totalYards')::numeric         / NULLIF((s->>'games')::int, 0), 1) AS yards_pg,
    round((s->>'totalYardsOpponent')::numeric / NULLIF((s->>'games')::int, 0), 1) AS opp_yards_pg,
    (s->>'firstDowns')::int                                    AS first_downs,
    (s->>'firstDownsOpponent')::int                            AS opp_first_downs,

    (s->>'passCompletions')::int                               AS pass_comp,
    (s->>'passAttempts')::int                                  AS pass_att,
    (s->>'netPassingYards')::int                               AS pass_yards,
    (s->>'passingTDs')::int                                    AS pass_tds,
    (s->>'passCompletionsOpponent')::int                       AS opp_pass_comp,
    (s->>'passAttemptsOpponent')::int                          AS opp_pass_att,
    (s->>'netPassingYardsOpponent')::int                       AS opp_pass_yards,
    (s->>'passingTDsOpponent')::int                            AS opp_pass_tds,

    (s->>'rushingAttempts')::int                               AS rush_att,
    (s->>'rushingYards')::int                                  AS rush_yards,
    (s->>'rushingTDs')::int                                    AS rush_tds,
    (s->>'rushingAttemptsOpponent')::int                       AS opp_rush_att,
    (s->>'rushingYardsOpponent')::int                          AS opp_rush_yards,
    (s->>'rushingTDsOpponent')::int                            AS opp_rush_tds,

    (s->>'thirdDownConversions')::int                          AS third_down_conv,
    (s->>'thirdDowns')::int                                    AS third_downs,
    (s->>'thirdDownConversionsOpponent')::int                  AS opp_third_down_conv,
    (s->>'thirdDownsOpponent')::int                            AS opp_third_downs,
    (s->>'fourthDownConversions')::int                         AS fourth_down_conv,
    (s->>'fourthDowns')::int                                   AS fourth_downs,
    (s->>'fourthDownConversionsOpponent')::int                 AS opp_fourth_down_conv,
    (s->>'fourthDownsOpponent')::int                           AS opp_fourth_downs,

    -- ---------- turnovers ----------
    -- API naming: "interceptions" = thrown by this team's offense,
    --             "passesIntercepted" = made by this team's defense
    (s->>'turnovers')::int                                     AS turnovers,
    (s->>'turnoversOpponent')::int                             AS takeaways,
    (s->>'interceptions')::int                                 AS ints_thrown,
    (s->>'fumblesLost')::int                                   AS fumbles_lost,
    (s->>'passesIntercepted')::int                             AS def_interceptions,
    (s->>'fumblesRecovered')::int                              AS fumbles_recovered,
    (s->>'interceptionYards')::int                             AS int_return_yards,
    (s->>'interceptionTDs')::int                               AS int_return_tds,

    -- ---------- defense (2016+ only) ----------
    (s->>'sacks')::int                                         AS sacks,
    (s->>'sacksOpponent')::int                                 AS opp_sacks,
    (s->>'tacklesForLoss')::int                                AS tackles_for_loss,
    (s->>'tacklesForLossOpponent')::int                        AS opp_tackles_for_loss,

    -- ---------- penalties / possession ----------
    (s->>'penalties')::int                                     AS penalties,
    (s->>'penaltyYards')::int                                  AS penalty_yards,
    (s->>'penaltiesOpponent')::int                             AS opp_penalties,
    (s->>'penaltyYardsOpponent')::int                          AS opp_penalty_yards,
    (s->>'possessionTime')::int                                AS possession_sec,
    round((s->>'possessionTime')::numeric / 60 / NULLIF((s->>'games')::int, 0), 1) AS possession_min_pg,

    -- ---------- special teams (kick returns 2005+) ----------
    (s->>'kickReturns')::int                                   AS kick_returns,
    (s->>'kickReturnYards')::int                               AS kick_return_yards,
    (s->>'kickReturnTDs')::int                                 AS kick_return_tds,
    (s->>'puntReturns')::int                                   AS punt_returns,
    (s->>'puntReturnYards')::int                               AS punt_return_yards,
    (s->>'puntReturnTDs')::int                                 AS punt_return_tds,

    -- ---------- advanced: offense ----------
    (o->>'plays')::int                                         AS off_plays,
    (o->>'drives')::int                                        AS off_drives,
    (o->>'ppa')::numeric                                       AS off_ppa,
    (o->>'successRate')::numeric                               AS off_success_rate,
    (o->>'explosiveness')::numeric                             AS off_explosiveness,
    (o->>'powerSuccess')::numeric                              AS off_power_success,
    (o->>'stuffRate')::numeric                                 AS off_stuff_rate,
    (o->>'lineYards')::numeric                                 AS off_line_yards,
    (o->>'secondLevelYards')::numeric                          AS off_second_level_yards,
    (o->>'openFieldYards')::numeric                            AS off_open_field_yards,
    (o->>'pointsPerOpportunity')::numeric                      AS off_points_per_opp,
    (o->'fieldPosition'->>'averageStart')::numeric             AS off_avg_start,
    (o->'havoc'->>'total')::numeric                            AS off_havoc_allowed,
    (o->'standardDowns'->>'ppa')::numeric                      AS off_std_downs_ppa,
    (o->'standardDowns'->>'successRate')::numeric              AS off_std_downs_success,
    (o->'passingDowns'->>'ppa')::numeric                       AS off_pass_downs_ppa,
    (o->'passingDowns'->>'successRate')::numeric               AS off_pass_downs_success,
    (o->'rushingPlays'->>'ppa')::numeric                       AS off_rush_ppa,
    (o->'rushingPlays'->>'successRate')::numeric               AS off_rush_success,
    (o->'passingPlays'->>'ppa')::numeric                       AS off_pass_ppa,
    (o->'passingPlays'->>'successRate')::numeric               AS off_pass_success,

    -- ---------- advanced: defense (values allowed to opponents) ----------
    (d->>'plays')::int                                         AS def_plays,
    (d->>'drives')::int                                        AS def_drives,
    (d->>'ppa')::numeric                                       AS def_ppa,
    (d->>'successRate')::numeric                               AS def_success_rate,
    (d->>'explosiveness')::numeric                             AS def_explosiveness,
    (d->>'powerSuccess')::numeric                              AS def_power_success,
    (d->>'stuffRate')::numeric                                 AS def_stuff_rate,
    (d->>'lineYards')::numeric                                 AS def_line_yards,
    (d->>'secondLevelYards')::numeric                          AS def_second_level_yards,
    (d->>'openFieldYards')::numeric                            AS def_open_field_yards,
    (d->>'pointsPerOpportunity')::numeric                      AS def_points_per_opp,
    (d->'fieldPosition'->>'averageStart')::numeric             AS def_avg_start,
    (d->'havoc'->>'total')::numeric                            AS def_havoc,
    (d->'standardDowns'->>'ppa')::numeric                      AS def_std_downs_ppa,
    (d->'standardDowns'->>'successRate')::numeric              AS def_std_downs_success,
    (d->'passingDowns'->>'ppa')::numeric                       AS def_pass_downs_ppa,
    (d->'passingDowns'->>'successRate')::numeric               AS def_pass_downs_success,
    (d->'rushingPlays'->>'ppa')::numeric                       AS def_rush_ppa,
    (d->'rushingPlays'->>'successRate')::numeric               AS def_rush_success,
    (d->'passingPlays'->>'ppa')::numeric                       AS def_pass_ppa,
    (d->'passingPlays'->>'successRate')::numeric               AS def_pass_success
FROM basic b
LEFT JOIN adv  a USING (season, team)
LEFT JOIN rec  r USING (season, team)
LEFT JOIN pts  p USING (season, team);

ALTER TABLE marts.team_season_stats ADD PRIMARY KEY (season, team);
CREATE INDEX ix_team_season_stats_conf ON marts.team_season_stats (season, conf);
