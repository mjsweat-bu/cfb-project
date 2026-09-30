SELECT count(*) AS games, min(season), max(season) FROM core.games;   -- expect 18,300, 2004-2025
SELECT count(*) FROM core.team_games;                                  -- expect 36,600
SELECT round(avg(possession_home_sec + possession_away_sec)) AS avg_total_sec
FROM core.games
WHERE possession_home_sec IS NOT NULL AND possession_away_sec IS NOT NULL;  -- expect ~3600