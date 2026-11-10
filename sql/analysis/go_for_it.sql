WITH df AS (
    SELECT f.*, g.game_date,
           CASE WHEN f.outcome = 'converted' THEN 1 ELSE 0 END AS convert_target
    FROM marts.fourth_down_features f
    JOIN core.games g ON g.game_id = f.game_id
    WHERE f.decision = 'go'
)
SELECT
    d.*,
    -- earlier attempts by this offense in this game
    count(*)            OVER game_prior AS fourth_down_atts_game,
    sum(convert_target) OVER game_prior AS fourth_down_conv_game,
    -- earlier attempts by this offense this season (previous games + earlier in this game)
    count(*)            OVER szn_prior  AS fourth_down_atts_season,
    sum(convert_target) OVER szn_prior  AS fourth_down_conv_season
FROM df d
WINDOW
    game_prior AS (PARTITION BY offense, game_id ORDER BY play_id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
    szn_prior  AS (PARTITION BY offense, season ORDER BY game_date, game_id, play_id
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
