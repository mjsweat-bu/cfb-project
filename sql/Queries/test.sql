-- Row-count and sanity checks for the game-level core and mart tables.
-- Each query should return the "expect" value in its comment.

-- one row per game, 2004 to the current season
SELECT count(*) AS games, min(season), max(season) FROM core.games;         -- expect ~18,700, 2004-2026

-- exactly two team rows per game
SELECT count(*) FROM core.games g
WHERE (SELECT count(*) FROM core.team_games t WHERE t.game_id = g.game_id) <> 2;  -- expect 0

-- team_games scores agree with games
SELECT count(*) FROM core.team_games t JOIN core.games g USING (game_id)
WHERE t.points_for <> CASE WHEN t.team = g.home_team THEN g.score_home ELSE g.score_away END;  -- expect 0

-- box-score coverage by season (has_stats share of team-games)
SELECT season, round(avg(has_stats::int), 3) AS stats_share, round(avg(has_pbp::int), 3) AS pbp_share
FROM core.team_games GROUP BY season ORDER BY season;                       -- expect stats_share ~0.95+

-- turnovers = fumbles lost + interceptions thrown
SELECT count(*) FROM core.team_games
WHERE has_stats AND turnovers <> fumbles_lost + ints_thrown;                -- expect 0

-- one feature row per game
SELECT (SELECT count(*) FROM marts.game_features) - (SELECT count(*) FROM core.games);  -- expect 0


