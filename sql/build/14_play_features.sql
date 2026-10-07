-- =====================================================
-- marts.play_features: one row per scrimmage snap (2008+), for a model of
-- "will this drive score?" that can be re-scored live, snap by snap.
-- Every feature is known BEFORE the snap and has a /live/plays equivalent
-- (no timeouts, no play results). Target: drive_scored.
-- Sources: core.plays (04), core.drives (05), core.team_games (06),
-- core.game_spreads (08), core.games (03). Safe to re-run.
--
-- Rows: core.plays.is_scrimmage (run/pass on downs 1-4; kicks, penalties,
-- timeouts and 2-pt tries excluded), seasons 2008+ (play-by-play covers 96%+
-- of team-games from 2008). Split train/test by season, never randomly.
--
-- Situation at the snap
--   sec_left_in_half   seconds left in the half (NULL in overtime, and for the
--                      handful of plays with an impossible clock > 15:00)
--   score_margin       offense minus defense, BEFORE the snap
--   is_home / is_neutral   offense is the listed home team / neutral site
--   is_goal_to_go      distance >= yards to goal
-- Drive so far (earlier snaps on this drive only)
--   drive_play_num     1 = first snap of the drive
--   drive_yards_so_far, drive_ppa_so_far   sums over earlier snaps (0 on the first)
--   prev_play_success  previous snap's success flag (NULL on the first snap)
--   drive_start_ytg    yards to goal on the drive's first snap
-- Team strength (prior games this season only; NULL in a team's first game)
--   off_*_szn          the offense's season-to-date PPA, success rate, points per drive
--   def_*_szn          what the defense on the field has allowed: PPA, points per drive
--   off_elo / def_elo  pregame Elo of the offense / defense
--   offense_spread     closing spread from the offense's side (-7 = offense favored by 7), 2013+
--   off_games_prior / def_games_prior   games behind the season-to-date numbers
-- Target
--   drive_scored       1 if the drive ended in a TD or made FG (core.drives.is_scoring)
--   drive_result       the drive's result (TD, FG, PUNT, ...). For analysis only,
--                      never a feature.
-- =====================================================
CREATE SCHEMA IF NOT EXISTS marts;

DROP TABLE IF EXISTS marts.play_features;

CREATE TABLE marts.play_features AS
WITH strength AS (
    -- each team before each game: season-to-date averages over prior games
    SELECT game_id, team, pregame_elo,
        count(*) OVER s                                     AS games_prior,
        round(avg(off_ppa) OVER s, 3)                       AS off_ppa_szn,
        round(avg(off_success_rate) OVER s, 3)              AS off_success_szn,
        round(avg(points_per_drive) OVER s, 2)              AS off_ppd_szn,
        round(avg(def_ppa) OVER s, 3)                       AS def_ppa_szn,
        round(avg(opp_points_per_drive) OVER s, 2)          AS def_ppd_szn
    FROM core.team_games
    WINDOW s AS (PARTITION BY team, season ORDER BY game_date, game_id
                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
),
snaps AS (
    SELECT p.*,
        d.start_yards_to_goal                               AS drive_start_ytg,
        d.is_scoring,
        d.result,
        row_number() OVER w                                 AS drive_play_num,
        coalesce(sum(p.off_yards) OVER wp, 0)               AS drive_yards_so_far,
        coalesce(sum(p.ppa) OVER wp, 0)                     AS drive_ppa_so_far,
        lag(p.is_success) OVER w                            AS prev_play_success
    FROM core.plays p
    JOIN core.drives d ON d.drive_id = p.drive_id AND d.offense = p.offense
    WHERE p.is_scrimmage
      AND p.season >= 2008
      AND p.period >= 1
      AND p.yards_to_goal BETWEEN 1 AND 99      -- a few rows have impossible field position
    WINDOW w  AS (PARTITION BY p.drive_id, p.offense ORDER BY p.play_number),
           wp AS (w ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
)
SELECT
    -- keys (not features)
    s.play_id, s.drive_id, s.game_id, s.season, s.week, s.season_type,
    s.offense, s.defense,

    -- situation at the snap
    s.down,
    s.distance,
    s.yards_to_goal,
    s.period,
    CASE WHEN s.clock_sec > 900   THEN NULL
         WHEN s.period IN (1, 3)  THEN s.clock_sec + 900
         WHEN s.period IN (2, 4)  THEN s.clock_sec
    END                                                     AS sec_left_in_half,
    s.period > 4                                            AS is_overtime,
    s.pre_offense_score - s.pre_defense_score               AS score_margin,
    s.offense = s.home_team                                 AS is_home,
    g.is_neutral,
    s.distance >= s.yards_to_goal                           AS is_goal_to_go,

    -- drive so far
    s.drive_play_num,
    s.drive_yards_so_far,
    round(s.drive_ppa_so_far, 3)                            AS drive_ppa_so_far,
    s.prev_play_success,
    s.drive_start_ytg,

    -- team strength
    so.off_ppa_szn,
    so.off_success_szn,
    so.off_ppd_szn,
    sd.def_ppa_szn,
    sd.def_ppd_szn,
    so.pregame_elo                                          AS off_elo,
    sd.pregame_elo                                          AS def_elo,
    CASE WHEN s.offense = s.home_team THEN sp.spread ELSE -sp.spread END AS offense_spread,
    so.games_prior                                          AS off_games_prior,
    sd.games_prior                                          AS def_games_prior,

    -- target
    s.is_scoring::int                                       AS drive_scored,
    s.result                                                AS drive_result
FROM snaps s
LEFT JOIN core.games g         ON g.game_id = s.game_id
LEFT JOIN strength so          ON so.game_id = s.game_id AND so.team = s.offense
LEFT JOIN strength sd          ON sd.game_id = s.game_id AND sd.team = s.defense
LEFT JOIN core.game_spreads sp ON sp.game_id = s.game_id;

ALTER TABLE marts.play_features ADD PRIMARY KEY (play_id);
CREATE INDEX ix_play_features_season ON marts.play_features (season);
CREATE INDEX ix_play_features_drive  ON marts.play_features (drive_id, offense);

ANALYZE marts.play_features;
