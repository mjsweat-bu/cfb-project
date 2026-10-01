-- Opening-possession three-and-outs: how often a team's FIRST possession of a game
-- ends with a punt on the 4th play (three plays, then punt), all-time, for every FBS team.
-- Change the highlighted team and minimum games in `params`.
-- Source: core.plays (play-by-play 2001-2026; early seasons are incomplete in the API).
-- Definitions:
--   * Plays counted: the team's scrimmage plays and punts. Penalties, timeouts and
--     kickoffs are not plays here (the API files the opponent's opening kickoff under
--     the same drive number, so plays are filtered to the team's own offense).
--   * First possession: the team's lowest-numbered drive in the game with a scrimmage
--     play or punt.
--   * Three-and-out punt: the 4th counted play of that drive is a punt (any punt type,
--     including blocked / returned) and the first three are scrimmage plays.
--   * FBS: team-seasons in marts.team_season_stats (2004+); for 2001-2003, teams that
--     were FBS in 2004 stand in, since there is no FBS list for those years.
--   * Rank 1 = lowest rate (best at avoiding the opening three-and-out).
WITH params AS (
    SELECT 'Auburn' AS team, 40 AS min_games
),
fbs AS (
    SELECT season, team FROM marts.team_season_stats
    UNION
    SELECT s.season, t.team
    FROM generate_series(2001, 2003) AS s(season)
    CROSS JOIN (SELECT team FROM marts.team_season_stats WHERE season = 2004) t
),
team_plays AS (
    -- the team's own scrimmage plays and punts
    SELECT p.season, p.game_id, p.offense AS team, p.drive_number, p.play_number, p.play_type,
           p.is_scrimmage, p.play_type ILIKE '%punt%' AS is_punt
    FROM core.plays p
    JOIN fbs f ON f.season = p.season AND f.team = p.offense
    WHERE p.is_scrimmage OR p.play_type ILIKE '%punt%'
),
first_drive AS (
    SELECT game_id, team, min(drive_number) AS drive_number
    FROM team_plays
    GROUP BY game_id, team
),
first_possession AS (
    SELECT tp.*,
           row_number() OVER (PARTITION BY tp.game_id, tp.team ORDER BY tp.play_number) AS play_seq
    FROM team_plays tp
    JOIN first_drive fd USING (game_id, team, drive_number)
),
games AS (
    SELECT
        team,
        game_id,
        min(season)                                                         AS season,
        count(*) FILTER (WHERE is_scrimmage)                                AS scrimmage_plays,
        bool_or(play_seq = 4 AND is_punt)
          AND count(*) FILTER (WHERE play_seq <= 3 AND is_scrimmage) = 3    AS three_and_out_punt
    FROM first_possession
    GROUP BY team, game_id
),
by_team AS (
    SELECT
        team,
        count(*)                                                            AS games,
        count(*) FILTER (WHERE three_and_out_punt)                          AS opening_3_and_out_punts,
        round(100.0 * count(*) FILTER (WHERE three_and_out_punt) / count(*), 1) AS pct_of_games,
        round(avg(scrimmage_plays), 2)                                      AS avg_plays_first_possession,
        min(season)                                                         AS first_season,
        max(season)                                                         AS last_season,
        count(DISTINCT season)                                              AS seasons
    FROM games
    GROUP BY team
)
SELECT
    rank() OVER (ORDER BY b.pct_of_games, b.games DESC)                    AS rank_fewest,
    count(*) OVER ()                                                        AS teams_ranked,
    b.*,
    b.team = x.team                                                         AS is_highlighted_team
FROM by_team b
CROSS JOIN params x
WHERE b.games >= x.min_games
ORDER BY rank_fewest;
