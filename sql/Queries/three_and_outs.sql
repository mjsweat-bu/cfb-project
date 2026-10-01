-- Three-and-outs on ANY drive: every drive where the punt is the 4th play (three plays,
-- then punt), all-time, ranked for every FBS team. Change the highlighted team,
-- minimum games and conference filter in `params`.
-- Source: core.plays (play-by-play 2001-2026; early seasons are incomplete in the API).
-- Definitions (same as first_possession_three_and_out.sql, without the first-drive rule):
--   * Plays counted: the team's scrimmage plays and punts. Penalties, timeouts and
--     kickoffs are not plays here, so "rush, false start, rush, incompletion, punt"
--     is a three-and-out.
--   * Drive: a team's drive with at least one scrimmage play or punt.
--   * Three-and-out: the 4th counted play of the drive is a punt (any punt type) and
--     the first three are scrimmage plays.
--   * FBS: team-seasons in marts.team_season_stats (2004+); for 2001-2003, teams that
--     were FBS in 2004 stand in.
--   * Conference filter (`params`): conf = NULL means all FBS. Names as in
--     marts.team_season_stats: 'ACC', 'American Athletic', 'Big 12', 'Big Ten',
--     'Conference USA', 'FBS Independents', 'Mid-American', 'Mountain West',
--     'Pac-12', 'SEC', 'Sun Belt'.
--       conf_seasons_only = false: teams currently in that conference, all of their
--         seasons (e.g. SEC includes Texas's Big 12 years).
--       conf_seasons_only = true: only seasons the team spent in that conference
--         (e.g. SEC includes Texas from 2024, and Missouri from 2012).
--     2001-2003 use each team's 2004 conference. Ranks are within the filter.
--   * rank_most = ranked by total count (1 = most). Totals favor teams with more games
--     in the data, so rate ranks are included too (1 = highest rate).
WITH params AS (
    SELECT 'Auburn'  AS team,
           40        AS min_games,
           'SEC'     AS conf,                -- NULL for all FBS
           false     AS conf_seasons_only    -- true = only seasons spent in `conf`
),
fbs AS (
    SELECT season, team, conf FROM marts.team_season_stats
    UNION
    SELECT s.season, t.team, t.conf
    FROM generate_series(2001, 2003) AS s(season)
    CROSS JOIN (SELECT team, conf FROM marts.team_season_stats WHERE season = 2004) t
),
current_conf AS (
    -- each team's conference in its most recent season
    SELECT DISTINCT ON (team) team, conf
    FROM fbs
    ORDER BY team, season DESC
),
in_scope AS (
    -- team-seasons that pass the conference filter
    SELECT f.season, f.team
    FROM fbs f
    JOIN current_conf c USING (team)
    CROSS JOIN params x
    WHERE x.conf IS NULL
       OR (x.conf_seasons_only AND f.conf = x.conf)
       OR (NOT x.conf_seasons_only AND c.conf = x.conf)
),
team_plays AS (
    -- the team's own scrimmage plays and punts, numbered within each drive
    SELECT p.season, p.game_id, p.offense AS team, p.drive_number, p.is_scrimmage,
           p.play_type ILIKE '%punt%' AS is_punt,
           row_number() OVER (PARTITION BY p.game_id, p.offense, p.drive_number
                              ORDER BY p.play_number) AS play_seq
    FROM core.plays p
    JOIN in_scope s ON s.season = p.season AND s.team = p.offense
    WHERE p.is_scrimmage OR p.play_type ILIKE '%punt%'
),
drives AS (
    SELECT
        team,
        game_id,
        min(season)                                                         AS season,
        bool_or(play_seq = 4 AND is_punt)
          AND count(*) FILTER (WHERE play_seq <= 3 AND is_scrimmage) = 3    AS three_and_out
    FROM team_plays
    GROUP BY team, game_id, drive_number
),
by_team AS (
    SELECT
        team,
        count(DISTINCT game_id)                                             AS games,
        count(*)                                                            AS drives,
        count(*) FILTER (WHERE three_and_out)                               AS three_and_outs,
        round(count(*) FILTER (WHERE three_and_out)::numeric
              / count(DISTINCT game_id), 2)                                 AS per_game,
        round(100.0 * count(*) FILTER (WHERE three_and_out) / count(*), 1)  AS pct_of_drives,
        min(season)                                                         AS first_season,
        max(season)                                                         AS last_season,

        -- three-and-outs by season, 2016-2026 (2026 = season to date).
        -- When a new season starts, add a column for it.
        count(*) FILTER (WHERE three_and_out AND season = 2016)            AS y2016,
        count(*) FILTER (WHERE three_and_out AND season = 2017)            AS y2017,
        count(*) FILTER (WHERE three_and_out AND season = 2018)            AS y2018,
        count(*) FILTER (WHERE three_and_out AND season = 2019)            AS y2019,
        count(*) FILTER (WHERE three_and_out AND season = 2020)            AS y2020,
        count(*) FILTER (WHERE three_and_out AND season = 2021)            AS y2021,
        count(*) FILTER (WHERE three_and_out AND season = 2022)            AS y2022,
        count(*) FILTER (WHERE three_and_out AND season = 2023)            AS y2023,
        count(*) FILTER (WHERE three_and_out AND season = 2024)            AS y2024,
        count(*) FILTER (WHERE three_and_out AND season = 2025)            AS y2025,
        count(*) FILTER (WHERE three_and_out AND season = 2026)            AS y2026
    FROM drives
    GROUP BY team
)
SELECT
    rank() OVER (ORDER BY b.three_and_outs DESC)                            AS rank_most,
    rank() OVER (ORDER BY b.pct_of_drives DESC)                             AS rank_pct_of_drives,
    rank() OVER (ORDER BY b.per_game DESC)                                  AS rank_per_game,
    count(*) OVER ()                                                        AS teams_ranked,
    b.*,
    c.conf                                                                  AS current_conf,
    b.team = x.team                                                         AS is_highlighted_team
FROM by_team b
JOIN current_conf c USING (team)
CROSS JOIN params x
WHERE b.games >= x.min_games
ORDER BY rank_most, b.team;
