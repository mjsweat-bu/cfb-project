-- Opening-possession three-and-outs: how often a team's FIRST possession of a game
-- ends with a punt on the 4th play (three plays, then punt), all-time, for every FBS team.
-- Change the highlighted team and minimum games in `params`.
-- Source: core.drives (built from play-by-play 2001-2026; early seasons are incomplete in the API).
-- Definitions:
--   * Plays counted: the team's scrimmage plays and punts. Penalties, timeouts and
--     kickoffs are not plays here (the API files the opponent's opening kickoff under
--     the same drive number, so plays are filtered to the team's own offense).
--   * First possession: the team's first drive of the game in core.drives
--     (team_drive_seq = 1): one with a scrimmage play, punt or field goal try.
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
games AS (
    -- the team's first possession of each game
    SELECT d.offense AS team, d.game_id, d.season,
           d.plays                                                          AS scrimmage_plays,
           d.three_and_out                                                  AS three_and_out_punt
    FROM core.drives d
    JOIN fbs f ON f.season = d.season AND f.team = d.offense
    WHERE d.team_drive_seq = 1
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
