-- Every 4th down in one season, with the columns all four decision models need
-- (go-for-it, field goal, punt, expected points). Used by
-- notebooks/fourth_down_predictor/fourth_down_decision.ipynb:
--
--     plays = read_query("fourth_down_decisions.sql", season=2025)
--
-- Each model learned only from plays where that choice was made; to score all three
-- options on every 4th down, the features below are rebuilt for every play:
--   * go:  attempts / conversions earlier in the game and season, counting go plays only
--          (same numbers as the go_for_it_model query on go plays)
--   * fg:  career history of the kicker the offense would send out: the team's
--          kicker in this game if it attempted a field goal, otherwise its most
--          recent kicker before this game (same numbers as the field_goal_model
--          query on field goal plays)
WITH params AS (
    SELECT 2025 AS season
),

fourth AS (
    SELECT f.*, g.game_date,
           CASE WHEN f.decision = 'go' AND f.outcome = 'converted' THEN 1 ELSE 0 END AS convert_target
    FROM marts.fourth_down_features f
    JOIN core.games g ON g.game_id = f.game_id
),

-- ---------- go-for-it history (prior go attempts by this offense) ----------
go_history AS (
    SELECT
        play_id,
        count(*)            FILTER (WHERE decision = 'go' AND distance > 0) OVER game_prior AS fourth_down_atts_game,
        sum(convert_target) FILTER (WHERE decision = 'go' AND distance > 0) OVER game_prior AS fourth_down_conv_game,
        count(*)            FILTER (WHERE decision = 'go' AND distance > 0) OVER szn_prior  AS fourth_down_atts_season,
        sum(convert_target) FILTER (WHERE decision = 'go' AND distance > 0) OVER szn_prior  AS fourth_down_conv_season
    FROM fourth
    WINDOW
        game_prior AS (PARTITION BY offense, game_id ORDER BY play_id
                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
        szn_prior  AS (PARTITION BY offense, season ORDER BY game_date, game_id, play_id
                       ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
),

-- ---------- kicker history (same parsing as field_goal_model) ----------
fg AS (
    SELECT
        f.offense, f.game_id, f.game_date, f.outcome, f.kick_distance,
        coalesce(
            substring(p.play_text FROM '(?i)(\d+)\s*(?:yd|yard)s?\.?\s+(?:field goal|fg)'),
            substring(p.play_text FROM '(?i)(?:field goal|fg)\s+attempt\s+from\s+(\d+)')
        )::int AS raw_num,
        coalesce(
            substring(p.play_text FROM '(?i)#\d+\s+(\S+(?:\s+(?!field|fg)\S+)?)\s+(?:field goal|fg)'),
            substring(p.play_text FROM '(?i)(?:field goal|fg)\s+(?:is\s+)?(?:good\s+)?by\s+([A-Za-z.''\-]+(?:\s+[A-Za-z.''\-]+){0,2}?)\s*(?:\(|,|$)'),
            substring(p.play_text FROM '(?i)^((?:[A-Za-z.''\-]+\s+){0,2}[A-Za-z.''\-]+)\s+(?:\d+\s*(?:yd|yard)s?\.?\s+)?(?:field goal|fg)')
        ) AS raw_name
    FROM fourth f
    LEFT JOIN core.plays p ON p.play_id = f.play_id
    WHERE f.decision = 'field goal'
),
named AS (
    SELECT
        fg.*,
        upper(left(regexp_replace(raw_name, '[\s,]+(Jr\.?|Sr\.?|II|III|IV)$', '', 'i'), 1)) || '.' ||
        upper(substring(regexp_replace(raw_name, '[\s,]+(Jr\.?|Sr\.?|II|III|IV)$', '', 'i')
                        FROM '([A-Za-z''\-]+)$')) AS kicker,
        coalesce(CASE WHEN raw_num BETWEEN 17 AND 70 THEN raw_num END, kick_distance) AS kick_distance_fixed
    FROM fg
),
kicker_games AS (
    SELECT
        kicker, offense, game_id, game_date,
        count(*)                                                                             AS attempts,
        sum(CASE WHEN outcome = 'fg_made' THEN 1 ELSE 0 END)                                 AS makes,
        sum(CASE WHEN kick_distance_fixed >= 50 THEN 1 ELSE 0 END)                           AS long_att,
        sum(CASE WHEN kick_distance_fixed >= 50 AND outcome = 'fg_made' THEN 1 ELSE 0 END)   AS long_makes,
        max(CASE WHEN outcome = 'fg_made' THEN kick_distance_fixed ELSE 0 END)               AS longest_made
    FROM named
    WHERE kicker IS NOT NULL
    GROUP BY kicker, offense, game_id, game_date
),
kicker_totals AS (
    -- career totals per kicker + team: before this game, and through this game
    SELECT
        kg.*,
        coalesce(sum(attempts)   OVER before, 0) AS att_before,
        coalesce(sum(makes)      OVER before, 0) AS makes_before,
        coalesce(sum(long_att)   OVER before, 0) AS long_att_before,
        coalesce(sum(long_makes) OVER before, 0) AS long_makes_before,
        coalesce(max(longest_made) OVER before, 0) AS longest_before,
        sum(attempts)     OVER thru AS att_thru,
        sum(makes)        OVER thru AS makes_thru,
        sum(long_att)     OVER thru AS long_att_thru,
        sum(long_makes)   OVER thru AS long_makes_thru,
        max(longest_made) OVER thru AS longest_thru
    FROM kicker_games kg
    WINDOW
        before AS (PARTITION BY kicker, offense ORDER BY game_date, game_id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
        thru   AS (PARTITION BY kicker, offense ORDER BY game_date, game_id
                   ROWS UNBOUNDED PRECEDING)
),
team_kicking_games AS (
    -- one kicker per team per game (the one with the most attempts), and the team's
    -- next kicking game: each row is "the team's kicker" until that next game
    SELECT
        t.*,
        lead(game_date) OVER w AS next_date,
        lead(game_id)   OVER w AS next_game_id
    FROM (
        SELECT DISTINCT ON (offense, game_id) *
        FROM kicker_totals
        ORDER BY offense, game_id, attempts DESC
    ) t
    WINDOW w AS (PARTITION BY offense ORDER BY game_date, game_id)
),
team_games AS (
    SELECT DISTINCT offense, game_id, game_date
    FROM fourth
    WHERE season = (SELECT season FROM params)
),
team_kicker AS (
    -- this game's kicker (history before the game), else the latest earlier kicker (history through his last game)
    SELECT
        tg.offense, tg.game_id, k.kicker,
        CASE WHEN k.game_id = tg.game_id THEN k.att_before        ELSE k.att_thru        END AS k_att,
        CASE WHEN k.game_id = tg.game_id THEN k.makes_before      ELSE k.makes_thru      END AS k_makes,
        CASE WHEN k.game_id = tg.game_id THEN k.long_att_before   ELSE k.long_att_thru   END AS k_long_att,
        CASE WHEN k.game_id = tg.game_id THEN k.long_makes_before ELSE k.long_makes_thru END AS k_long_makes,
        CASE WHEN k.game_id = tg.game_id THEN k.longest_before    ELSE k.longest_thru    END AS k_longest
    FROM team_games tg
    LEFT JOIN team_kicking_games k
        ON  k.offense = tg.offense
        AND (k.game_date, k.game_id) <= (tg.game_date, tg.game_id)
        AND (k.next_date IS NULL OR (k.next_date, k.next_game_id) > (tg.game_date, tg.game_id))
)

SELECT
    f.*,
    gh.fourth_down_atts_game,
    gh.fourth_down_conv_game,
    gh.fourth_down_atts_season,
    gh.fourth_down_conv_season,
    tk.kicker,
    f.kick_distance                                                          AS kick_distance_fixed,
    coalesce(tk.k_att, 0)                                                    AS kicker_att_prior,
    coalesce(tk.k_makes, 0)                                                  AS kicker_makes_prior,
    coalesce(tk.k_makes / nullif(tk.k_att, 0), 0)                            AS kicker_all_time_pct,
    coalesce(tk.k_long_att, 0)                                               AS kicker_long_distance_atts,
    coalesce(tk.k_long_makes, 0)                                             AS kicker_long_distance_makes,
    coalesce(tk.k_long_makes / nullif(tk.k_long_att, 0), 0)                  AS kicker_long_distance_pct,
    coalesce(tk.k_longest, 0)                                                AS kicker_longest_kick
FROM fourth f
JOIN go_history gh ON gh.play_id = f.play_id
LEFT JOIN team_kicker tk ON tk.offense = f.offense AND tk.game_id = f.game_id
WHERE f.season = (SELECT season FROM params)
ORDER BY f.game_date, f.game_id, f.play_id
