-- QBs on 3rd down: average distance to go, average yards gained, conversion rate.
-- One row per QB (all seasons combined). Uncomment the team line to limit to one team.
-- Plays have no player IDs, so a QB's plays are matched from play_text, e.g.
-- "Cameron Newton pass incomplete" / "Bo Nix run for 4 yds" / "Payton Thorne sacked by ...".
-- Matching uses first initial + last name, because names differ between
-- sources (roster "Cam Newton" vs play-by-play "Cameron Newton"), and from
-- 2025 the play text also uses "(05:06) Shotgun #12 A.Daniels pass ..." format.
-- Each play is only checked against its own offense's QBs (q.team = p.offense):
-- without that, every play is regex-matched against every QB in the season
-- (~270M checks, runs for hours) and same-named QBs get each other's plays.
-- Counts dropbacks (passes, sacks, interceptions) and the QB's own runs.
-- Play-by-play is loaded for 2010 and 2016+.
WITH qbs AS (
    SELECT DISTINCT season, team, player_id, player, first_name, last_name
    FROM marts.player_season_stats
    WHERE (position = 'QB' OR pass_att >= 10)
      AND last_name IS NOT NULL
      -- AND team = 'Auburn'
),
qb_plays AS (
    SELECT q.player_id, q.player, q.team, p.season, p.distance, p.off_yards, p.play_category
    FROM core.plays p
    JOIN qbs q
      ON q.season = p.season
     AND q.team = p.offense
     AND p.play_text ~* ('(^' || left(q.first_name, 1) || '\S*\s+'      -- "Cameron Newton ..."
                         || '|#\d+\s+' || left(q.first_name, 1) || '\.)'   -- "#12 A.Daniels ..."
                         || q.last_name
                         || '\M(\s+(Jr\.?|Sr\.?|II|III|IV))?\s+(pass|rush|run|sacked|scrambles?)\M')
    WHERE p.down = 3
      AND p.is_scrimmage
)
SELECT
    player,
    string_agg(DISTINCT team, ', ')                     AS teams,
    min(season)                                         AS first_season,
    max(season)                                         AS last_season,
    count(*)                                            AS third_down_plays,
    round(avg(distance), 2)                             AS avg_distance_to_go,
    round(avg(off_yards), 2)                            AS avg_yards_gained,
    round(avg((off_yards >= distance)::int), 3)         AS conversion_rate,
    round(avg((play_category = 'pass')::int), 3)        AS pass_rate
FROM qb_plays
GROUP BY player_id, player
HAVING count(*) >= 5           -- skip mop-up QBs
ORDER BY conversion_rate DESC;
