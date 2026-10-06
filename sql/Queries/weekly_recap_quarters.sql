-- Weekly recap: offensive efficiency by quarter for both teams in the team's
-- game in `week`. Change team / season / week in `params`.
-- Source: core.plays, scrimmage plays only (sacks count as pass plays,
-- interceptions as 0 yards). Overtime periods are grouped as 'OT'.
-- explosive = scrimmage play gaining 20+ yards.
WITH params AS (
    SELECT 'Auburn'::text AS team, 2026 AS season, 5 AS week
),
g AS (
    SELECT t.game_id, t.team
    FROM core.team_games t
    JOIN params x ON x.team = t.team AND x.season = t.season AND x.week = t.week
                AND t.season_type = 'regular'   -- postseason weeks restart at 1
)
SELECT
    p.offense,
    p.offense = g.team                                         AS is_team,
    CASE WHEN p.period <= 4 THEN 'Q' || p.period ELSE 'OT' END AS quarter,
    count(*)                                                   AS plays,
    round(avg(p.off_yards), 2)                                 AS yards_per_play,
    round(avg(p.is_success::int), 3)                           AS success_rate,
    round(avg(p.ppa), 3)                                       AS ppa_per_play,
    round(avg((p.play_category = 'pass')::int), 3)             AS pass_rate,
    count(*) FILTER (WHERE p.off_yards >= 20)                  AS explosive_plays
FROM core.plays p
JOIN g ON g.game_id = p.game_id
WHERE p.is_scrimmage
GROUP BY p.offense, g.team, 3
ORDER BY is_team DESC, quarter;
