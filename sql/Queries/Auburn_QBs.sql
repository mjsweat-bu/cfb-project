-- Auburn QBs with their Auburn-only stats (seasons at other schools excluded).
-- Built from marts.player_season_stats rather than marts.player_career_stats:
-- career rows combine every school a player attended, and their `teams` column
-- lists all of them (e.g. 'Auburn, Oregon'), so `teams = 'Auburn'` drops transfers.
-- A player counts as a QB if listed at QB or had 10+ pass attempts at Auburn
-- (Cam Newton's 2010 roster row has no position).
SELECT
    player,
    min(season)                                                  AS first_season,
    max(season)                                                  AS last_season,
    count(DISTINCT season)                                       AS seasons,
    sum(pass_comp)                                               AS pass_comp,
    sum(pass_att)                                                AS pass_att,
    round(sum(pass_comp)::numeric / NULLIF(sum(pass_att), 0), 3) AS pass_pct,
    sum(pass_yards)                                              AS pass_yards,
    sum(pass_tds)                                                AS pass_tds,
    sum(pass_ints)                                               AS pass_ints,
    sum(rush_att)                                                AS rush_att,
    sum(rush_yards)                                              AS rush_yards,
    sum(rush_tds)                                                AS rush_tds,
    sum(ppa_total)                                               AS ppa_total      -- 2013+
FROM marts.player_season_stats
WHERE (team = 'Auburn' OR player = 'Cam Newton')
    AND pass_comp is not NULL
    AND pass_att > 10
GROUP BY player_id, player
HAVING bool_or(position = 'QB') OR sum(pass_att) >= 10
ORDER BY last_season DESC, pass_yards DESC NULLS LAST;
