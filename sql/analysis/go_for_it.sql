WITH df as (
    SELECT
    *,
    CASE WHEN outcome = 'converted' THEN 1 ELSE 0 END as CONVERT_TARGET
FROM marts.fourth_down_features
),

team_attempts_per_game AS (
    SELECT
        p.offense, p.game_id, g.game_date,
        SUM(CASE WHEN p.decision = 'go' THEN 1 ELSE 0 END)            as fourth_down_atts_game,
        SUM(CASE WHEN p.convert_target = 1 THEN 1 ELSE 0 END)         as fourth_down_conv_game
    FROM df p
    LEFT JOIN core.games g
        ON g.game_id = p.game_id
    GROUP BY p.offense, p.game_id, g.game_date
),

team_attempts_per_season AS (
    SELECT
        p.offense, p.season,
        SUM(CASE WHEN p.decision = 'go' THEN 1 ELSE 0 END)            as fourth_down_atts_season,
        SUM(CASE WHEN p.convert_target = 1 THEN 1 ELSE 0 END)         as fourth_down_conv_season
    FROM df p
    LEFT JOIN core.games g
        ON g.game_id = p.game_id
    GROUP BY p.offense, p.season
)

SELECT 
    d.*,
    pg.fourth_down_atts_game,
    pg.fourth_down_conv_game,
    ps.fourth_down_atts_season,
    ps.fourth_down_conv_season
FROM df d
LEFT JOIN team_attempts_per_game pg
    ON d.game_id = pg.game_id
LEFT JOIN team_attempts_per_season ps
    ON ps.offense = d.offense
    AND ps.season = d.season
WHERE decision = 'go'




