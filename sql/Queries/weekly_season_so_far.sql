-- The team's regular season through `week`: one row per game played.
-- Change team / season / week in `params` (the notebook weekly_report.ipynb sets them).
-- Source: core.team_games, core.game_spreads (closing line; ats = against the spread).
WITH params AS (
    SELECT 'Auburn'::text AS team, 2026 AS season, 5 AS week
)
SELECT
    t.week,
    t.game_date,
    CASE t.location WHEN 'home' THEN 'vs' WHEN 'away' THEN 'at' ELSE 'vs (N)' END AS site,
    t.opponent,
    CASE WHEN t.win THEN 'W' ELSE 'L' END                            AS result,
    t.points_for || '-' || t.points_against                          AS score,
    t.margin,
    ts.team_spread,                                                  -- -7 = team favored by 7
    CASE WHEN ts.team_spread IS NULL      THEN NULL
         WHEN t.margin + ts.team_spread > 0 THEN 'covered'
         WHEN t.margin + ts.team_spread < 0 THEN 'missed'
         ELSE 'push' END                                             AS ats,
    t.total_yards,
    t.opp_total_yards,
    t.off_ppa,
    t.def_ppa,
    t.turnovers,
    t.takeaways
FROM core.team_games t
JOIN params x ON x.team = t.team AND x.season = t.season AND t.week <= x.week
                AND t.season_type = 'regular'   -- postseason weeks restart at 1
LEFT JOIN core.game_spreads s ON s.game_id = t.game_id
-- spreads are stored from the home side; flip when the team is listed as away
CROSS JOIN LATERAL (
    SELECT CASE WHEN s.home_team = t.team THEN s.spread ELSE -s.spread END AS team_spread
) ts
ORDER BY t.game_date;
