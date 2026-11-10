-- =====================================================
-- marts.fourth_down_features: one row per 4th-down decision (go / field goal /
-- punt) with its outcome, for training the 4th-down decision models.
-- Features are known before the snap; `outcome` is the target. See the comment
-- above the final SELECT for the columns left out because they would leak it.
-- Build 04, 05, 06 and 08 first. Safe to re-run.
-- =====================================================
CREATE SCHEMA IF NOT EXISTS marts;

DROP TABLE IF EXISTS marts.fourth_down_features;

CREATE TABLE marts.fourth_down_features AS
-- Takes a drive and sees what happens on next sequential drive
WITH drive_seq as (
    SELECT
        d.drive_id,
        d.offense,
        lead(d.offense) OVER w AS next_offense,
        lead(d.start_yards_to_goal) OVER w as Next_start_ytg,
        lead(d.start_period) OVER w AS next_start_period
    FROM core.drives d
    WINDOW w AS (PARTITION BY d.game_id ORDER by d.drive_number, d.drive_id)
),

-- Fourth Down decisions and their outcomes
fourth_downs as (
SELECT *,
    CASE 
        WHEN is_scrimmage                   THEN 'go'
        WHEN play_type ILIKE '%punt%'       THEN 'punt'
        WHEN play_type ILIKE '%field goal%' THEN 'field goal'
        END AS decision,
        pre_offense_score - pre_defense_score          AS score_margin,
        CASE WHEN period IN (1, 3) THEN clock_sec + 900
             WHEN period IN (2, 4) THEN clock_sec END  AS sec_left_in_half,
        yards_to_goal + 17                             AS kick_distance,
        distance >= yards_to_goal                      AS is_goal_to_go,
        offense = home_team                            AS is_home
FROM core.plays
WHERE down = 4
),

-- Team Strength
strength AS (
    SELECT game_id, team, pregame_elo,
        count(*)              OVER s AS games_prior,   -- how much data the averages rest on
        avg(off_ppa)          OVER s AS off_ppa_szn,
        avg(off_success_rate) OVER s AS off_success_szn,
        avg(def_ppa)          OVER s AS def_ppa_szn
    FROM core.team_games
    WINDOW s AS (PARTITION BY team, season ORDER BY game_date, game_id
                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
),

-- Kicker Strength
fg_games AS (
    SELECT p.game_id, p.offense AS team,
           count(*)                                         AS fg_att,
           count(*) FILTER (WHERE p.play_type = 'Field Goal Good') AS fg_made
    FROM core.plays p
    WHERE p.play_type ILIKE '%field goal%'
    GROUP BY 1, 2
),
kicking AS (
    SELECT t.game_id, t.team,
           (sum(coalesce(g.fg_made, 0)) OVER s)::numeric
             / NULLIF(sum(coalesce(g.fg_att, 0)) OVER s, 0) AS fg_pct_szn,
           sum(coalesce(g.fg_att, 0)) OVER s                AS fg_att_szn   -- 1-for-1 vs 15-for-20
    FROM core.team_games t
    LEFT JOIN fg_games g ON g.game_id = t.game_id AND g.team = t.team
    WINDOW s AS (PARTITION BY t.team, t.season ORDER BY t.game_date, t.game_id
                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
),

-- every 4th-down decision with its outcome and all context columns
labeled AS (
SELECT
    f.*,
    o.opp_start_ytg,
    CASE WHEN f.decision = 'punt'
         THEN f.yards_to_goal - (100 - o.opp_start_ytg)
    END                                                     AS net_punt_yards,

    -- team strength going into the game (earlier games this season only)
    so.off_ppa_szn,
    so.off_success_szn,
    sd.def_ppa_szn,                                         -- the defense they're facing
    so.pregame_elo                                          AS off_elo,
    sd.pregame_elo                                          AS def_elo,
    k.fg_pct_szn,
    k.fg_att_szn,
    so.games_prior                                          AS off_games_prior,
    CASE WHEN f.offense = f.home_team THEN sp.spread ELSE -sp.spread END AS offense_spread,  -- -7 = offense favored by 7
    g.is_neutral,

    -- what came after
    d.result                                                AS drive_result_after,
    tg.win                                                  AS game_won,

    CASE
        -- go
        WHEN (f.decision = 'go' AND off_yards >= distance)  OR  off_yards >= yards_to_goal THEN 'converted'
        WHEN f.decision = 'go' AND f.play_type ILIKE ANY (ARRAY['%intercept%', 'Fumble Recovery (Opponent)', 'Fumble Return Touchdown']) THEN 'turnover'
        WHEN f.decision = 'go' THEN 'failed'

        -- field goals
        WHEN f.play_type = 'Field Goal Good'                                    THEN 'fg_made'
        WHEN f.play_type ILIKE '%blocked%'  AND f.decision = 'field goal'       THEN 'fg_blocked'
        WHEN f.decision = 'field goal'                                          THEN 'fg_missed'

        -- punt
        WHEN f.play_type ILIKE '%blocked%'                                      THEN 'punt_blocked'
        WHEN f.play_type = 'Punt Return Touchdown'                              -- many return TDs are typed
          OR f.play_text ~* '(for a|for the) (TD|touchdown)|touchdown'          -- as plain 'Punt'
                                                                                THEN 'punt_return_td'
        WHEN n.next_offense IS NULL                                             -- no drive after it in the game
          OR (n.next_start_period <= 2) <> (f.period <= 2)                      THEN 'punt_end_of_half'
        -- the punting team has the next drive:
        WHEN n.next_offense = f.offense
         AND f.play_text ~* 'muff|fumble'                                       THEN 'punt_muffed'   -- kicking team recovered
        WHEN n.next_offense = f.offense
         AND f.play_text ~* 'penalty|roughing|running into'                     THEN 'punt_penalty_first_down'  -- kicking team kept the ball
        WHEN n.next_offense = f.offense                                         THEN 'punt_unknown'  -- receiving team's possession missing from the play-by-play
        WHEN n.next_start_ytg = 80                                             THEN 'punt_touchback'  -- college punt touchback = the 20
        ELSE                                                                        'punt_returned'
    END as outcome
FROM fourth_downs f
LEFT JOIN drive_seq n
    ON n.drive_id = f.drive_id
    AND n.offense = f.offense
-- where the opponent took over, computed once so net_punt_yards can reuse it
CROSS JOIN LATERAL (
    SELECT CASE WHEN n.next_offense = f.defense                    -- the opponent got the ball
                 AND (n.next_start_period <= 2) = (f.period <= 2)  -- in the same half
                THEN n.next_start_ytg
           END AS opp_start_ytg
) o
LEFT JOIN strength so       ON so.game_id = f.game_id AND so.team = f.offense
LEFT JOIN strength sd       ON sd.game_id = f.game_id AND sd.team = f.defense
LEFT JOIN kicking k         ON k.game_id  = f.game_id AND k.team  = f.offense
LEFT JOIN core.game_spreads sp ON sp.game_id = f.game_id
LEFT JOIN core.games g      ON g.game_id  = f.game_id
LEFT JOIN core.drives d     ON d.drive_id = f.drive_id AND d.offense = f.offense
LEFT JOIN core.team_games tg ON tg.game_id = f.game_id AND tg.team = f.offense
WHERE f.decision IS NOT NULL   -- drop penalties, timeouts and period markers
)

-- ---------- training table for the multiclass outcome model ----------
-- Only what is known BEFORE the snap, plus the target.
-- Left out on purpose (they describe the result, so they would leak it):
--   play_type, play_text, off_yards, yards_gained, ppa, is_success, scoring,
--   offense_score / defense_score (after the play), opp_start_ytg, net_punt_yards,
--   drive_result_after, game_won, play_category (the play call itself).
-- Also left out: down (always 4), timeouts (not in the live feed).
SELECT
    -- keys: split train/test by season, group by game; not features
    play_id,
    game_id,
    drive_id,
    season,
    week,
    offense,
    defense,

    -- the choice the coach made (the model predicts the outcome given the choice)
    decision,

    -- situation before the snap
    distance,
    yards_to_goal,
    kick_distance,
    is_goal_to_go,
    period,
    period > 4                                              AS is_overtime,
    CASE WHEN clock_sec <= 900 THEN sec_left_in_half END    AS sec_left_in_half,   -- NULL: OT or bad clock
    CASE WHEN period <= 4 AND clock_sec <= 900
         THEN (4 - period) * 900 + clock_sec END            AS sec_left_in_game,
    score_margin,
    is_home,
    is_neutral,

    -- team strength going in (earlier games this season only)
    off_ppa_szn,
    off_success_szn,
    def_ppa_szn,
    off_elo,
    def_elo,
    off_elo - def_elo                                       AS elo_diff,
    offense_spread,
    fg_pct_szn,
    fg_att_szn,
    off_games_prior,
    opp_start_ytg,
    net_punt_yards,

    -- target
    outcome
FROM labeled
WHERE outcome <> 'punt_unknown'                 -- result can't be known (missing possession)
  AND period >= 1
  AND yards_to_goal BETWEEN 1 AND 99            -- a few rows have impossible field position
;

ALTER TABLE marts.fourth_down_features ADD PRIMARY KEY (play_id);
CREATE INDEX ix_fourth_down_features_season ON marts.fourth_down_features (season, decision);

ANALYZE marts.fourth_down_features;
