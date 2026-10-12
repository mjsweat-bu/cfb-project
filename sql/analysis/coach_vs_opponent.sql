-- A head coach's record against one opponent, across every team he coached
-- (2000+). Defaults: Nick Saban vs. Auburn (LSU 2000-04, Alabama 2007-23).
-- Change coach / opponent in `params`; from Python:
--   read_query("coach_vs_opponent.sql", coach_first="Kirby", coach_last="Smart", opponent="Auburn")
-- Two queries: (1) record by split, (2) every game. The notebook loader splits
-- on the "-- ---------- 2." marker.
-- Sources: core.coach_seasons + core.poll_ranks (16), core.team_games (06),
-- core.game_spreads (08).
-- Definitions:
--   * Rank = AP Top 25 going INTO the game: the poll for the game's week
--     (week 1 = preseason poll); bowl games use the last regular-season poll.
--     Unranked = not in that week's AP Top 25.
--   * "Higher-ranked" compares the two ranks, with unranked counted as 26.
--   * Favorite / underdog uses the closing spread (lines start in 2013).
--   * One-score game = final margin of 8 points or fewer.
--   * A coach is credited with every game his team played in a season he
--     coached it (no mid-season splits; fine for full-season coaches).
WITH params AS (
    SELECT 'Nick'::text AS coach_first, 'Saban'::text AS coach_last, 'Auburn'::text AS opponent
),
coach_teams AS (
    SELECT DISTINCT cs.season, cs.team, cs.coach
    FROM core.coach_seasons cs
    JOIN params x ON x.coach_first = cs.first_name AND x.coach_last = cs.last_name
),
games AS (
    SELECT t.*, ct.coach
    FROM core.team_games t
    JOIN coach_teams ct ON ct.season = t.season AND ct.team = t.team
    JOIN params x ON x.opponent = t.opponent
),
poll_week AS (
    -- which AP poll applies to each game
    SELECT g.game_id,
           (SELECT max(pr.week) FROM core.poll_ranks pr
            WHERE pr.poll = 'AP Top 25' AND pr.season = g.season AND pr.season_type = 'regular'
              AND (g.season_type = 'postseason' OR pr.week <= g.week)) AS week
    FROM games g
),
g AS (
    SELECT
        g.*,
        tr.rank                                                     AS team_rank,
        orr.rank                                                    AS opp_rank,
        CASE WHEN s.home_team = g.team THEN s.spread ELSE -s.spread END AS team_spread   -- -7 = favored by 7
    FROM games g
    JOIN poll_week pw USING (game_id)
    LEFT JOIN core.poll_ranks tr  ON tr.poll = 'AP Top 25' AND tr.season = g.season AND tr.season_type = 'regular'
                                 AND tr.week = pw.week AND tr.team = g.team
    LEFT JOIN core.poll_ranks orr ON orr.poll = 'AP Top 25' AND orr.season = g.season AND orr.season_type = 'regular'
                                 AND orr.week = pw.week AND orr.team = g.opponent
    LEFT JOIN core.game_spreads s ON s.game_id = g.game_id
)

-- ---------- 1. Record by split ----------
SELECT
    v.split_type,
    v.split,
    count(*)                                                        AS games,
    count(*) FILTER (WHERE g.win)                                   AS wins,
    count(*) FILTER (WHERE NOT g.win)                               AS losses,
    round(avg(g.win::int), 3)                                       AS win_pct,
    round(avg(g.points_for), 1)                                     AS avg_points_for,
    round(avg(g.points_against), 1)                                 AS avg_points_against,
    round(avg(g.margin), 1)                                         AS avg_margin,
    string_agg(g.season::text, ', ' ORDER BY g.season) FILTER (WHERE NOT g.win) AS losses_in
FROM g
CROSS JOIN LATERAL (VALUES
    (1, 'Overall',          'All games'),
    (2, 'Coached team',     g.team),
    (3, 'Location',         initcap(g.location)),
    (4, 'Coach''s team',    CASE WHEN g.team_rank IS NULL THEN 'Unranked' ELSE 'Ranked' END),
    (5, 'Opponent',         CASE WHEN g.opp_rank  IS NULL THEN 'Unranked' ELSE 'Ranked' END),
    (6, 'Matchup',          CASE WHEN g.team_rank IS NOT NULL AND g.opp_rank IS NOT NULL THEN 'Both ranked'
                                 WHEN g.team_rank IS NOT NULL THEN 'Only coach''s team ranked'
                                 WHEN g.opp_rank  IS NOT NULL THEN 'Only opponent ranked'
                                 ELSE 'Neither ranked' END),
    (7, 'Rank comparison',  CASE WHEN coalesce(g.team_rank, 26) < coalesce(g.opp_rank, 26) THEN 'Coach''s team ranked higher'
                                 WHEN coalesce(g.team_rank, 26) > coalesce(g.opp_rank, 26) THEN 'Opponent ranked higher'
                                 ELSE 'Both unranked' END),
    (8, 'Opponent top 10',  CASE WHEN g.opp_rank <= 10 THEN 'Opponent in top 10' END),
    (9, 'Betting line',     CASE WHEN g.team_spread < 0 THEN 'Favorite'
                                 WHEN g.team_spread > 0 THEN 'Underdog'
                                 WHEN g.team_spread = 0 THEN 'Pick''em' END),
    (10, 'Game type',       CASE WHEN abs(g.margin) <= 8 THEN 'One-score game' ELSE 'Decided by 9+' END),
    (11, 'Season type',     initcap(g.season_type))
) AS v(sort, split_type, split)
WHERE v.split IS NOT NULL
GROUP BY v.sort, v.split_type, v.split
ORDER BY v.sort, games DESC, v.split;

-- ---------- 2. Every game ----------
WITH params AS (
    SELECT 'Nick'::text AS coach_first, 'Saban'::text AS coach_last, 'Auburn'::text AS opponent
),
coach_teams AS (
    SELECT DISTINCT cs.season, cs.team, cs.coach
    FROM core.coach_seasons cs
    JOIN params x ON x.coach_first = cs.first_name AND x.coach_last = cs.last_name
),
games AS (
    SELECT t.*, ct.coach
    FROM core.team_games t
    JOIN coach_teams ct ON ct.season = t.season AND ct.team = t.team
    JOIN params x ON x.opponent = t.opponent
),
poll_week AS (
    SELECT g.game_id,
           (SELECT max(pr.week) FROM core.poll_ranks pr
            WHERE pr.poll = 'AP Top 25' AND pr.season = g.season AND pr.season_type = 'regular'
              AND (g.season_type = 'postseason' OR pr.week <= g.week)) AS week
    FROM games g
)
SELECT
    g.season,
    g.game_date,
    g.team                                                          AS coach_team,
    CASE g.location WHEN 'home' THEN 'vs' WHEN 'away' THEN 'at' ELSE 'vs (N)' END AS site,
    g.opponent,
    tr.rank                                                         AS team_rank,
    orr.rank                                                        AS opp_rank,
    CASE WHEN g.win THEN 'W' ELSE 'L' END                           AS result,
    g.points_for || '-' || g.points_against                         AS score,
    g.margin,
    CASE WHEN s.home_team = g.team THEN s.spread ELSE -s.spread END AS team_spread
FROM games g
JOIN poll_week pw USING (game_id)
LEFT JOIN core.poll_ranks tr  ON tr.poll = 'AP Top 25' AND tr.season = g.season AND tr.season_type = 'regular'
                             AND tr.week = pw.week AND tr.team = g.team
LEFT JOIN core.poll_ranks orr ON orr.poll = 'AP Top 25' AND orr.season = g.season AND orr.season_type = 'regular'
                             AND orr.week = pw.week AND orr.team = g.opponent
LEFT JOIN core.game_spreads s ON s.game_id = g.game_id
ORDER BY g.game_date;
