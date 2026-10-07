-- Data coverage by season: share of team-games with an official box score
-- (has_stats) and with play-by-play (has_pbp), plus game counts.
-- Pass/fail data checks live in src/cfb/checks.py (run by python -m cfb.refresh and pytest).
-- Source: core.team_games.
SELECT
    season,
    count(*) / 2                              AS games,
    round(avg(has_stats::int), 3)             AS stats_share,
    round(avg(has_pbp::int), 3)               AS pbp_share
FROM core.team_games
GROUP BY season
ORDER BY season;
