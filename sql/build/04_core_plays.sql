-- =====================================================
-- core.plays: typed play-by-play from raw.api_plays (FBS games, 2016+)
-- Load raw data first:  python -m cfb.ingest_api plays 2016 2026
-- Safe to re-run.
--
-- Derived columns:
--   play_category  'rush' / 'pass' / 'other' for scrimmage plays, NULL otherwise
--                  (penalties, kicks, timeouts, period ends are NULL).
--                  Sacks count as pass plays. Fumbles are classified from play_text.
--   is_scrimmage   play_category IS NOT NULL and down 1-4 (drops 2-pt tries etc.)
--   off_yards      yards gained by the offense. Same as yards_gained, except
--                  interceptions and fumble-return TDs = 0 (the API's yardsGained
--                  there is the defense's return yards).
--   is_success     standard success rate: gain >= 50% of distance on 1st down,
--                  70% on 2nd, 100% on 3rd/4th
--   offense_score / defense_score   score AFTER the play (as the API reports it)
--   pre_offense_score / pre_defense_score   score BEFORE the play, from the previous
--                  play in the game (pre_home_score / pre_away_score from the home
--                  side). Use these for anything describing the situation at the snap.
-- =====================================================
CREATE SCHEMA IF NOT EXISTS core;

DROP TABLE IF EXISTS core.plays;

CREATE TABLE core.plays AS
WITH p AS (
    SELECT
        source_id                                          AS play_id,
        game_id,
        payload->>'driveId'                                AS drive_id,
        season,
        season_type,
        week,
        (payload->>'driveNumber')::int                     AS drive_number,
        (payload->>'playNumber')::int                      AS play_number,
        payload->>'offense'                                AS offense,
        payload->>'offenseConference'                      AS offense_conf,
        payload->>'defense'                                AS defense,
        payload->>'defenseConference'                      AS defense_conf,
        payload->>'home'                                   AS home_team,
        payload->>'away'                                   AS away_team,
        (payload->>'offenseScore')::int                    AS offense_score,
        (payload->>'defenseScore')::int                    AS defense_score,
        (payload->>'period')::int                          AS period,
        (payload->'clock'->>'minutes')::int * 60
          + (payload->'clock'->>'seconds')::int            AS clock_sec,
        (payload->>'offenseTimeouts')::int                 AS offense_timeouts,
        (payload->>'defenseTimeouts')::int                 AS defense_timeouts,
        (payload->>'yardsToGoal')::int                     AS yards_to_goal,
        (payload->>'down')::int                            AS down,
        (payload->>'distance')::int                        AS distance,
        (payload->>'yardsGained')::int                     AS yards_gained,
        payload->>'playType'                               AS play_type,
        payload->>'playText'                               AS play_text,
        (payload->>'ppa')::numeric                         AS ppa,
        (payload->>'scoring')::boolean                     AS scoring,
        (payload->>'wallclock')::timestamptz               AS wallclock
    FROM raw.api_plays
),
c AS (
    SELECT p.*,
        CASE
            WHEN play_type IN ('Rush', 'Rushing Touchdown')
                THEN 'rush'
            WHEN play_type IN ('Pass Reception', 'Pass Incompletion', 'Passing Touchdown',
                               'Pass Completion', 'Pass', 'Sack',
                               'Pass Interception', 'Pass Interception Return',
                               'Interception', 'Interception Return Touchdown')
                THEN 'pass'
            WHEN play_type IN ('Fumble', 'Fumble Recovery (Own)', 'Fumble Recovery (Opponent)',
                               'Fumble Return Touchdown', 'Safety')
                THEN CASE WHEN play_text ~* '\m(pass|sacked)\M' THEN 'pass'
                          WHEN play_text ~* '\m(run|rush)'      THEN 'rush'
                          ELSE 'other' END
        END AS play_category
    FROM p
),
s AS (
    -- score BEFORE the play: the API's offenseScore / defenseScore are after it
    -- (a TD row already includes the 7), so take the previous play's score
    SELECT c.*,
        coalesce(lag(CASE WHEN offense = home_team THEN offense_score ELSE defense_score END) OVER g, 0) AS pre_home_score,
        coalesce(lag(CASE WHEN offense = home_team THEN defense_score ELSE offense_score END) OVER g, 0) AS pre_away_score
    FROM c
    WINDOW g AS (PARTITION BY game_id ORDER BY drive_number, play_number, play_id)
)
SELECT s.*,
    CASE WHEN offense = home_team THEN pre_home_score ELSE pre_away_score END AS pre_offense_score,
    CASE WHEN offense = home_team THEN pre_away_score ELSE pre_home_score END AS pre_defense_score,
    (play_category IS NOT NULL AND down BETWEEN 1 AND 4)     AS is_scrimmage,
    CASE WHEN play_category IS NOT NULL
         THEN CASE WHEN play_type ILIKE '%interception%' OR play_type = 'Fumble Return Touchdown'
              THEN 0 ELSE yards_gained END
    END                                                      AS off_yards,
    CASE WHEN play_category IS NOT NULL AND down BETWEEN 1 AND 4 THEN
        CASE WHEN play_type ILIKE '%interception%' OR play_type = 'Fumble Return Touchdown' THEN false
             WHEN down = 1 THEN yards_gained >= 0.5 * distance
             WHEN down = 2 THEN yards_gained >= 0.7 * distance
             ELSE yards_gained >= distance END
    END                                                      AS is_success
FROM s;

ALTER TABLE core.plays ADD PRIMARY KEY (play_id);
CREATE INDEX ix_plays_game    ON core.plays (game_id);
CREATE INDEX ix_plays_offense ON core.plays (season, offense);
CREATE INDEX ix_plays_defense ON core.plays (season, defense);

-- refresh planner statistics so queries right after a rebuild get a good plan
ANALYZE core.plays;
