CREATE SCHEMA IF NOT EXISTS marts;

DROP TABLE IF EXISTS marts.expected_points;

CREATE TABLE marts.expected_points AS
WITH play_order AS (
    SELECT
        game_id, season, drive_number, play_number, play_id,
        offense, defense, home_team, away_team,
        period, clock_sec, down, distance, yards_to_goal, is_scrimmage,
        pre_offense_score - pre_defense_score                  AS score_margin,
        CASE
            WHEN offense = home_team THEN offense_score
            WHEN defense = home_team THEN defense_score
        END AS home_score,
        CASE
            WHEN offense = away_team THEN offense_score
            WHEN defense = away_team THEN defense_score
        END AS away_score
    FROM core.plays
),

play_seq AS (
    SELECT
        p.*,
        max(home_score) OVER (PARTITION BY game_id ORDER BY drive_number, play_number, play_id
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS home_score_clean,
        max(away_score) OVER (PARTITION BY game_id ORDER BY drive_number, play_number, play_id
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS away_score_clean
    FROM play_order p
),

points AS (
    SELECT
        p.*,
        home_score_clean - coalesce(lag(home_score_clean) OVER g, 0) AS home_points,
        away_score_clean - coalesce(lag(away_score_clean) OVER g, 0) AS away_points
    FROM play_seq p
    WINDOW g AS (PARTITION BY game_id ORDER BY drive_number, play_number, play_id)
),

labels AS (
    SELECT
        p.*,
        CASE
            WHEN home_points > 0 AND away_points > 0                THEN NULL   -- both teams at once: feed error
            WHEN greatest(home_points, away_points) BETWEEN 6 AND 8 THEN 'TD'
            WHEN greatest(home_points, away_points) = 3             THEN 'FG'
            WHEN greatest(home_points, away_points) = 2
                 AND is_scrimmage                                   THEN 'SAFETY'
        END AS score_type
    FROM points p
),

events AS (
    SELECT
        l.*,
        -- the team whose score went up, only for real scoring events
        CASE WHEN score_type IS NULL THEN NULL
             WHEN home_points > 0    THEN home_team
             ELSE away_team
        END                                                    AS scoring_team,
        CASE WHEN period IN (1, 2) THEN 1
             WHEN period IN (3, 4) THEN 2
        END                                                    AS half,           -- NULL = overtime
        row_number() OVER (PARTITION BY game_id ORDER BY drive_number, play_number, play_id) AS play_seq_num
    FROM labels l
),

next_score AS (
    SELECT
        e.*,
        -- among this play and every later play in the same half, the first scoring play
        min(CASE WHEN score_type IS NOT NULL THEN play_seq_num END)
            OVER (PARTITION BY game_id, half ORDER BY play_seq_num
                  ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)           AS next_score_seq
    FROM events e
)

SELECT
    -- keys
    n.play_id, n.game_id, n.season, n.offense, n.defense,
    -- features: the situation at the snap
    n.half,
    CASE WHEN n.clock_sec > 900       THEN NULL                       -- impossible clock value
         WHEN n.period IN (1, 3)      THEN n.clock_sec + 900          -- 1st / 3rd quarter: a full quarter still to go
         ELSE n.clock_sec
    END                                                        AS sec_left_in_half,
    n.down,
    least(n.distance, n.yards_to_goal)                         AS distance,       -- goal-to-go recorded past the goal line
    n.yards_to_goal,
    n.distance >= n.yards_to_goal                              AS is_goal_to_go,
    n.score_margin,                                                               -- optional: test with / without
    -- n.season (above) doubles as the optional scoring-trend feature
    -- the next score in the half, from this offense's point of view
    s.score_type                                               AS next_score_type,
    s.scoring_team                                             AS next_scoring_team,
    CASE
        WHEN s.score_type IS NULL          THEN 'no_score'
        WHEN s.scoring_team = n.offense    THEN 'off_' || lower(s.score_type)
        ELSE                                    'def_' || lower(s.score_type)
    END                                                        AS next_score_label,
    CASE
        WHEN s.score_type IS NULL THEN 0
        ELSE CASE s.score_type WHEN 'TD' THEN 7 WHEN 'FG' THEN 3 WHEN 'SAFETY' THEN 2 END
           * CASE WHEN s.scoring_team = n.offense THEN 1 ELSE -1 END
    END                                                        AS next_score_points
FROM next_score n
LEFT JOIN events s
    ON s.game_id = n.game_id
   AND s.play_seq_num = n.next_score_seq
WHERE n.is_scrimmage
  AND n.half IN (1, 2)                       -- no overtime
  AND n.season >= 2008                       -- play-by-play is incomplete before 2008
  AND n.distance > 0                         -- ~1,300 rows with a zero / negative distance
  AND n.yards_to_goal BETWEEN 1 AND 99       -- ~650 rows with impossible field position
