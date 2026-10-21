WITH fg AS (
    SELECT
        f.*,
        coalesce(
            substring(p.play_text FROM '(?i)(\d+)\s*(?:yd|yard)s?\.?\s+(?:field goal|fg)'),
            substring(p.play_text FROM '(?i)(?:field goal|fg)\s+attempt\s+from\s+(\d+)')
        )::int AS raw_num,
        -- kicker's name, from whichever of the three play-text formats matches
        coalesce(
            -- 1. Jersey format:  "#47 T.Woody field goal attempt from 25 yards"
            substring(p.play_text FROM '(?i)#\d+\s+(\S+(?:\s+(?!field|fg)\S+)?)\s+(?:field goal|fg)'),
            -- 2. "by" format:    "22 yard field goal by Alex Trlica (TTU) is good."
            substring(p.play_text FROM '(?i)(?:field goal|fg)\s+(?:is\s+)?(?:good\s+)?by\s+([A-Za-z.''\-]+(?:\s+[A-Za-z.''\-]+){0,2}?)\s*(?:\(|,|$)'),
            -- 3. Name first:     "Chase Contreraz 22 Yd Field Goal", "Kenny Byrd field goal attempt from 40"
            substring(p.play_text FROM '(?i)^((?:[A-Za-z.''\-]+\s+){0,2}[A-Za-z.''\-]+)\s+(?:\d+\s*(?:yd|yard)s?\.?\s+)?(?:field goal|fg)')
        ) AS raw_name
    FROM marts.fourth_down_features f
    LEFT JOIN core.plays p
        ON p.play_id = f.play_id
    WHERE f.decision = 'field goal'
),
named AS (
    -- one key per kicker: first initial + last word, upper case ("Daniel Carlson" -> "D.CARLSON"),
    -- suffixes dropped. game_date for ordering (postseason weeks restart at 1).
    SELECT
        fg.*,
        upper(left(regexp_replace(raw_name, '[\s,]+(Jr\.?|Sr\.?|II|III|IV)$', '', 'i'), 1)) || '.' ||
        upper(substring(regexp_replace(raw_name, '[\s,]+(Jr\.?|Sr\.?|II|III|IV)$', '', 'i')
                        FROM '([A-Za-z''\-]+)$')) AS kicker,
        g.game_date,
        coalesce(CASE WHEN raw_num BETWEEN 17 AND 70 THEN raw_num END, kick_distance) AS kick_distance_fixed
    FROM fg
    LEFT JOIN core.games g
        ON g.game_id = fg.game_id
),
kicker_games AS (
    SELECT
        kicker, offense, game_id, game_date
        ,count(*)                                                                       as attempts
        ,SUM(CASE WHEN outcome  = 'fg_made' THEN 1 ELSE 0 END)                          as makes
        ,SUM(CASE WHEN kick_distance_fixed >= 50 THEN 1 ELSE 0 END)                           as long_distance_kick_att
        ,SUM(CASE WHEN kick_distance_fixed >= 50 AND outcome = 'fg_made' THEN 1 ELSE 0 END)   as long_distance_kick_makes
        ,MAX(CASE WHEN outcome = 'fg_made' THEN kick_distance_fixed END)                as longest_made_kick   -- NULL if no make this game
    FROM named
    GROUP BY kicker, offense, game_id, game_date
),
kicker_history AS (
    -- each kicker's career totals from EARLIER games only (frame ends one game back).
    -- Keyed on kicker + team, so two kickers with the same key at different schools stay apart.
    SELECT kicker, offense, game_id,
           coalesce(sum(attempts) OVER w, 0)                    AS kicker_att_prior,
           coalesce(sum(makes)    OVER w, 0)                    AS kicker_makes_prior,
           coalesce(sum(long_distance_kick_makes) OVER w, 0)    AS kicker_long_distance_makes,
           coalesce(sum(long_distance_kick_att) OVER w, 0)      AS kicker_long_distance_atts,      
           max(longest_made_kick) OVER w                        AS kicker_longest_kick   -- NULL until his first make (unknown, not 0 yards)
    FROM kicker_games
    WINDOW w AS (PARTITION BY kicker, offense ORDER BY game_date, game_id
                 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
)

SELECT
    named.*,
    CASE WHEN raw_num BETWEEN 17 AND 70 THEN raw_num END                          AS yard_num,
    
    h.kicker_att_prior,
    h.kicker_makes_prior,
    COALESCE(h.kicker_makes_prior  / NULLIF(h.kicker_att_prior,0),0)                                     AS kicker_all_time_pct,
    h.kicker_long_distance_atts,
    h.kicker_long_distance_makes,
    COALESCE(h.kicker_long_distance_makes  / NULLIF(h.kicker_long_distance_atts,0),0)            AS kicker_long_distance_pct,
    h.kicker_longest_kick
    
FROM named
LEFT JOIN kicker_history h
    ON h.kicker = named.kicker AND h.offense = named.offense AND h.game_id = named.game_id
-- WHERE h.kicker IS NOT NULL
ORDER BY h.kicker_makes_prior DESC
