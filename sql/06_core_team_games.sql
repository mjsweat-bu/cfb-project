-- =====================================================
-- core.team_games: one row per team per game (two rows per game), 2004+
-- Every team in core.games, FCS opponents included (their rows only cover
-- games against FBS teams).
--   Game info and score   core.games (03)
--   Box score             raw.api_game_teams (/games/teams); has_stats = loaded
--   Drives                core.drives (05)            } has_pbp = the game has
--   PPA / success rate    core.plays (04), scrimmage  } play-by-play
--                         plays, garbage time included
-- Load raw data first:  python src\ingest_api.py game_teams 2004 2026
-- Build 03, 04 and 05 first. Safe to re-run.
--
-- Column notes:
--   location        'home' / 'away' / 'neutral'
--   pass_yards      net passing yards (sack yards subtracted), as in official stats
--   ints_thrown     interceptions thrown by this team's offense
--   turnovers       fumbles lost + interceptions thrown; takeaways = opponent's turnovers
--   possession_sec  time of possession in seconds
--   off_* / def_*   play-by-play: this team's offense / what its defense allowed
--                   (def_ppa: lower is better). Sacks count as pass plays here.
--   drives          possessions with at least one scrimmage play
--   points_per_drive  all points scored (incl. defensive and return TDs) / drives
--   opp_*           the same stat for the opponent
-- =====================================================
DROP TABLE IF EXISTS core.team_games;

CREATE TABLE core.team_games AS
WITH sides AS (
    SELECT game_id, season, week, season_type, game_date, is_neutral, is_conf_game, attendance,
           home_id AS team_id, home_team AS team, home_class AS class, home_conf AS conf,
           away_id AS opp_id,  away_team AS opponent, away_class AS opp_class, away_conf AS opp_conf,
           CASE WHEN is_neutral THEN 'neutral' ELSE 'home' END AS location,
           score_home AS points_for, score_away AS points_against,
           home_pregame_elo AS pregame_elo, away_pregame_elo AS opp_pregame_elo
    FROM core.games
    UNION ALL
    SELECT game_id, season, week, season_type, game_date, is_neutral, is_conf_game, attendance,
           away_id, away_team, away_class, away_conf,
           home_id, home_team, home_class, home_conf,
           CASE WHEN is_neutral THEN 'neutral' ELSE 'away' END,
           score_away, score_home,
           away_pregame_elo, home_pregame_elo
    FROM core.games
),
box_raw AS (
    -- one JSON object per team per game: {category: stat}
    SELECT r.game_id,
           (t->>'teamId')::int                                AS team_id,
           jsonb_object_agg(s->>'category', s->>'stat')       AS st
    FROM raw.api_game_teams r
    CROSS JOIN jsonb_array_elements(r.payload->'teams') t
    CROSS JOIN jsonb_array_elements(t->'stats') s
    GROUP BY r.game_id, t->>'teamId'
),
box AS (
    SELECT game_id, team_id,
        core.to_int(st->>'firstDowns')                                  AS first_downs,
        core.to_int(split_part(st->>'thirdDownEff', '-', 1))            AS third_conv,
        core.to_int(split_part(st->>'thirdDownEff', '-', 2))            AS third_att,
        core.to_int(split_part(st->>'fourthDownEff', '-', 1))           AS fourth_conv,
        core.to_int(split_part(st->>'fourthDownEff', '-', 2))           AS fourth_att,
        core.to_int(split_part(st->>'completionAttempts', '-', 1))      AS pass_comp,
        core.to_int(split_part(st->>'completionAttempts', '-', 2))      AS pass_att,
        core.to_int(st->>'netPassingYards')                             AS pass_yards,
        core.to_int(st->>'passingTDs')                                  AS pass_tds,
        core.to_int(st->>'rushingAttempts')                             AS rush_att,
        core.to_int(st->>'rushingYards')                                AS rush_yards,
        core.to_int(st->>'rushingTDs')                                  AS rush_tds,
        core.to_int(st->>'totalYards')                                  AS total_yards,
        core.to_int(st->>'fumblesLost')                                 AS fumbles_lost,
        core.to_int(st->>'interceptions')                               AS ints_thrown,
        core.to_int(st->>'turnovers')                                   AS turnovers,
        core.to_int(split_part(st->>'totalPenaltiesYards', '-', 1))     AS penalties,
        core.to_int(split_part(st->>'totalPenaltiesYards', '-', 2))     AS penalty_yards,
        core.to_seconds(st->>'possessionTime')                          AS possession_sec
    FROM box_raw
),
off AS (
    SELECT game_id, offense AS team,
        count(*)                                                        AS plays,
        round(avg(ppa), 3)                                              AS ppa,
        round(avg(is_success::int), 3)                                  AS success_rate
    FROM core.plays
    WHERE is_scrimmage
    GROUP BY game_id, offense
),
drv AS (
    SELECT game_id, offense AS team,
        count(*)                                                        AS drives,
        count(*) FILTER (WHERE is_scoring)                              AS scoring_drives,
        count(*) FILTER (WHERE result = 'TD')                           AS td_drives,
        count(*) FILTER (WHERE three_and_out)                           AS three_and_outs,
        round(avg(start_yards_to_goal), 1)                              AS avg_start_yards_to_goal
    FROM core.drives
    WHERE plays > 0
    GROUP BY game_id, offense
)
SELECT
    s.game_id, s.season, s.week, s.season_type, s.game_date,
    s.team_id, s.team, s.class, s.conf,
    s.opp_id, s.opponent, s.opp_class, s.opp_conf,
    s.location, s.is_conf_game, s.attendance,
    s.pregame_elo, s.opp_pregame_elo,

    -- ---------- result ----------
    s.points_for, s.points_against,
    s.points_for - s.points_against                                     AS margin,
    s.points_for > s.points_against                                     AS win,

    -- ---------- box score ----------
    b.game_id IS NOT NULL                                               AS has_stats,
    b.first_downs, b.third_conv, b.third_att, b.fourth_conv, b.fourth_att,
    b.pass_comp, b.pass_att, b.pass_yards, b.pass_tds,
    b.rush_att, b.rush_yards, b.rush_tds, b.total_yards,
    b.fumbles_lost, b.ints_thrown, b.turnovers,
    ob.turnovers                                                        AS takeaways,
    b.penalties, b.penalty_yards, b.possession_sec,
    ob.first_downs                                                      AS opp_first_downs,
    ob.third_conv                                                       AS opp_third_conv,
    ob.third_att                                                        AS opp_third_att,
    ob.pass_yards                                                       AS opp_pass_yards,
    ob.rush_yards                                                       AS opp_rush_yards,
    ob.total_yards                                                      AS opp_total_yards,
    ob.penalties                                                        AS opp_penalties,
    ob.penalty_yards                                                    AS opp_penalty_yards,

    -- ---------- play-by-play ----------
    o.game_id IS NOT NULL                                               AS has_pbp,
    o.plays                                                             AS off_plays,
    o.ppa                                                               AS off_ppa,
    o.success_rate                                                      AS off_success_rate,
    d.plays                                                             AS def_plays,
    d.ppa                                                               AS def_ppa,
    d.success_rate                                                      AS def_success_rate,

    -- ---------- drives ----------
    dr.drives, dr.scoring_drives, dr.td_drives, dr.three_and_outs,
    dr.avg_start_yards_to_goal,
    round(s.points_for::numeric / NULLIF(dr.drives, 0), 2)              AS points_per_drive,
    odr.drives                                                          AS opp_drives,
    odr.scoring_drives                                                  AS opp_scoring_drives,
    odr.td_drives                                                       AS opp_td_drives,
    odr.three_and_outs                                                  AS opp_three_and_outs,
    odr.avg_start_yards_to_goal                                         AS opp_avg_start_yards_to_goal,
    round(s.points_against::numeric / NULLIF(odr.drives, 0), 2)         AS opp_points_per_drive
FROM sides s
LEFT JOIN box b   ON b.game_id = s.game_id  AND b.team_id = s.team_id
LEFT JOIN box ob  ON ob.game_id = s.game_id AND ob.team_id = s.opp_id
LEFT JOIN off o   ON o.game_id = s.game_id  AND o.team = s.team
LEFT JOIN off d   ON d.game_id = s.game_id  AND d.team = s.opponent
LEFT JOIN drv dr  ON dr.game_id = s.game_id AND dr.team = s.team
LEFT JOIN drv odr ON odr.game_id = s.game_id AND odr.team = s.opponent;

ALTER TABLE core.team_games ADD PRIMARY KEY (game_id, team);
CREATE INDEX ix_team_games_team ON core.team_games (team, season);
CREATE INDEX ix_team_games_conf ON core.team_games (season, conf);

ANALYZE core.team_games;
