-- =====================================================
-- core.drives: one row per offensive possession (2001+), built from core.plays
-- Build 04_core_plays.sql first. Safe to re-run.
--
-- Grain: (drive_id, offense). The API files the kickoff under the same drive_id as
-- the receiving team's possession, so a drive_id can hold two offenses; the kicking
-- team's side is dropped. A row exists only if the offense ran a scrimmage play,
-- punted or tried a field goal on the drive.
--
-- Columns:
--   team_drive_seq   the offense's nth possession of the game (1 = first possession)
--   start_* / end_*  first / last scrimmage play of the drive (falls back to the
--                    first / last punt or FG try on drives with no scrimmage play).
--                    Clock is at the snap; the API has no drive end time.
--   start_margin     offense score minus defense score at the drive's first play
--   plays            scrimmage plays (down 1-4 run/pass; penalties, kicks,
--                    timeouts and 2-pt tries excluded). Sacks count as pass plays.
--   yards            sum of off_yards on scrimmage plays (penalty yards not included)
--   penalties        penalty plays filed under the offense's drive (either team's)
--   third_conv / fourth_conv   3rd/4th-down scrimmage plays with yards >= distance
--                    (4th-down attempts are go-for-it plays; punts and FG tries are
--                    not scrimmage plays). First downs by penalty are not counted.
--   result           how the drive ended:
--                    TD         offensive touchdown anywhere on the drive (some TDs are
--                               typed 'Rush' / 'Pass Reception' with scoring = true)
--                    otherwise the drive's last play among scrimmage plays, punts,
--                    FG tries and safeties:
--                    FG, MISSED FG (incl. blocked), PUNT (any punt type),
--                    INT, FUMBLE (lost), SAFETY,
--                    DOWNS      last play was a 4th-down scrimmage play short of the line,
--                    END OF HALF / END OF GAME   last play in Q2 / Q4 or OT,
--                    OTHER      anything else (mostly data gaps)
--   is_scoring       result is TD or FG (defensive and return scores don't count)
--   three_and_out    counting only scrimmage plays and punts, the 4th is a punt and
--                    the first three are scrimmage plays (penalties don't count)
-- =====================================================
DROP TABLE IF EXISTS core.drives;

CREATE TABLE core.drives AS
WITH op AS (
    -- the offense's own plays on each drive, with the flags used below
    SELECT p.*,
        p.play_type ILIKE '%punt%'                                          AS is_punt,
        p.play_type IN ('Field Goal Good', 'Field Goal Missed', 'Blocked Field Goal',
                        'Blocked Field Goal Touchdown', 'Missed Field Goal Return',
                        'Missed Field Goal Return Touchdown')               AS is_fg_try,
        p.scoring AND p.play_type IN ('Rushing Touchdown', 'Passing Touchdown',
                                      'Rush', 'Pass Reception', 'Pass Completion',
                                      'Fumble Recovery (Own)')              AS is_off_td
    FROM core.plays p
),
op2 AS (
    SELECT op.*,
        -- plays that can end a drive
        (is_scrimmage OR is_punt OR is_fg_try OR play_type = 'Safety'
         OR play_type ILIKE '%intercept%'
         OR play_type IN ('Fumble Recovery (Opponent)', 'Fumble Return Touchdown')) AS is_action
    FROM op
),
d AS (
    SELECT
        drive_id,
        offense,
        min(game_id)                                                        AS game_id,
        min(season)                                                         AS season,
        min(season_type)                                                    AS season_type,
        min(week)                                                           AS week,
        min(offense_conf)                                                   AS offense_conf,
        min(defense)                                                        AS defense,
        min(defense_conf)                                                   AS defense_conf,
        min(home_team)                                                      AS home_team,
        min(away_team)                                                      AS away_team,
        min(drive_number)                                                   AS drive_number,

        -- start / end: first and last action play (scrimmage play preferred)
        coalesce((array_agg(period        ORDER BY play_number) FILTER (WHERE is_scrimmage))[1],
                 (array_agg(period        ORDER BY play_number) FILTER (WHERE is_action))[1])    AS start_period,
        coalesce((array_agg(clock_sec     ORDER BY play_number) FILTER (WHERE is_scrimmage))[1],
                 (array_agg(clock_sec     ORDER BY play_number) FILTER (WHERE is_action))[1])    AS start_clock_sec,
        coalesce((array_agg(yards_to_goal ORDER BY play_number) FILTER (WHERE is_scrimmage))[1],
                 (array_agg(yards_to_goal ORDER BY play_number) FILTER (WHERE is_action))[1])    AS start_yards_to_goal,
        (array_agg(offense_score - defense_score ORDER BY play_number))[1]                       AS start_margin,
        (array_agg(offense_score ORDER BY play_number))[1]                                       AS start_offense_score,
        (array_agg(defense_score ORDER BY play_number))[1]                                       AS start_defense_score,
        (array_agg(period        ORDER BY play_number DESC) FILTER (WHERE is_action))[1]         AS end_period,
        (array_agg(clock_sec     ORDER BY play_number DESC) FILTER (WHERE is_action))[1]         AS end_clock_sec,
        (array_agg(yards_to_goal ORDER BY play_number DESC) FILTER (WHERE is_action))[1]         AS end_yards_to_goal,

        -- volume
        count(*) FILTER (WHERE is_scrimmage)                                AS plays,
        count(*) FILTER (WHERE is_scrimmage AND play_category = 'pass')     AS pass_plays,
        count(*) FILTER (WHERE is_scrimmage AND play_category = 'rush')     AS rush_plays,
        count(*) FILTER (WHERE play_type = 'Sack')                          AS sacks,
        coalesce(sum(off_yards) FILTER (WHERE is_scrimmage), 0)             AS yards,
        count(*) FILTER (WHERE play_type = 'Penalty')                       AS penalties,
        round(sum(ppa) FILTER (WHERE is_scrimmage), 3)                      AS ppa_total,
        count(*) FILTER (WHERE is_success)                                  AS successful_plays,

        -- 3rd / 4th down
        count(*) FILTER (WHERE is_scrimmage AND down = 3)                   AS third_att,
        count(*) FILTER (WHERE is_scrimmage AND down = 3 AND off_yards >= distance) AS third_conv,
        count(*) FILTER (WHERE is_scrimmage AND down = 4)                   AS fourth_att,
        count(*) FILTER (WHERE is_scrimmage AND down = 4 AND off_yards >= distance) AS fourth_conv,

        -- ending
        bool_or(is_off_td)                                                  AS has_off_td,
        (array_agg(play_type ORDER BY play_number DESC) FILTER (WHERE is_action))[1]       AS last_play_type,
        (array_agg(down ORDER BY play_number DESC) FILTER (WHERE is_action))[1]            AS last_down,
        (array_agg(off_yards >= distance ORDER BY play_number DESC) FILTER (WHERE is_action))[1] AS last_gained_line,
        (array_agg(is_scrimmage ORDER BY play_number DESC) FILTER (WHERE is_action))[1]    AS last_is_scrimmage,

        -- three-and-out: scrimmage plays and punts in order
        (array_agg(is_punt ORDER BY play_number) FILTER (WHERE is_scrimmage OR is_punt))   AS seq_is_punt
    FROM op2
    GROUP BY drive_id, offense
    HAVING bool_or(is_scrimmage OR is_punt OR is_fg_try)
)
SELECT
    drive_id,
    game_id,
    season,
    season_type,
    week,
    offense,
    offense_conf,
    defense,
    defense_conf,
    offense = home_team                                                     AS is_home,
    drive_number,
    row_number() OVER (PARTITION BY game_id, offense ORDER BY drive_number, drive_id)::int AS team_drive_seq,
    start_period,
    start_clock_sec,
    start_yards_to_goal,
    start_offense_score,
    start_defense_score,
    start_margin,
    end_period,
    end_clock_sec,
    end_yards_to_goal,
    plays,
    pass_plays,
    rush_plays,
    sacks,
    yards,
    penalties,
    ppa_total,
    successful_plays,
    third_att,
    third_conv,
    fourth_att,
    fourth_conv,
    CASE
        WHEN has_off_td                                         THEN 'TD'
        WHEN last_play_type = 'Field Goal Good'                 THEN 'FG'
        WHEN last_play_type IN ('Field Goal Missed', 'Blocked Field Goal',
                                'Blocked Field Goal Touchdown', 'Missed Field Goal Return',
                                'Missed Field Goal Return Touchdown')
                                                                THEN 'MISSED FG'
        WHEN last_play_type ILIKE '%punt%'                      THEN 'PUNT'
        WHEN last_play_type ILIKE '%intercept%'                 THEN 'INT'
        WHEN last_play_type IN ('Fumble Recovery (Opponent)', 'Fumble Return Touchdown')
                                                                THEN 'FUMBLE'
        WHEN last_play_type = 'Safety'                          THEN 'SAFETY'
        WHEN last_is_scrimmage AND last_down = 4 AND NOT last_gained_line
                                                                THEN 'DOWNS'
        WHEN end_period = 2                                     THEN 'END OF HALF'
        WHEN end_period >= 4                                    THEN 'END OF GAME'
        ELSE 'OTHER'
    END                                                                     AS result,
    has_off_td OR last_play_type = 'Field Goal Good'                        AS is_scoring,
    coalesce(seq_is_punt[4] AND NOT (seq_is_punt[1] OR seq_is_punt[2] OR seq_is_punt[3]), false)
                                                                            AS three_and_out
FROM d;

ALTER TABLE core.drives ADD PRIMARY KEY (drive_id, offense);
CREATE INDEX ix_drives_game    ON core.drives (game_id);
CREATE INDEX ix_drives_offense ON core.drives (season, offense);
CREATE INDEX ix_drives_defense ON core.drives (season, defense);

ANALYZE core.drives;
