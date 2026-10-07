-- Drives that ended in an interception, by team and QB, plus a list of every interception.
-- Change the season or conference in `params` (default SEC 2026).
-- Source: core.plays. Definitions:
--   * Interception plays: play_type contains 'intercept' ('Interception',
--     'Pass Interception Return', 'Interception Return Touchdown'). An
--     interception always ends the drive.
--   * "Before the INT" = earlier plays on the same drive by the same offense.
--     Pass plays exclude sacks (sacks are counted separately); penalties are
--     not plays here.
--   * Play # in drive = scrimmage plays before the INT + 1 (1 = first snap).
--   * Return yards are read from the play text ("return 34 yards", "return for
--     loss of 3 yards"); the API's yards_gained on these plays is unreliable.
--   * QB hurried = play text mentions "hurried" (only in newer play text).
--   * Score margin = offense minus defense at the start of the drive.
--   * Two-minute = INT in the last 2:00 of the 2nd or 4th quarter.
--   * QB = passer named in the play text. Query 1 shows one QB per team: the
--     one with the most pass plays (sacks excluded). Backups' interceptions are
--     not counted there; query 2 still lists every interception by every QB.
--   * INTs per 100 passes uses all of that QB's pass plays.

-- ---------- 1. By team, main QB only ----------
WITH params AS (
    SELECT 2026 AS season, 'SEC' AS conf
),
plays AS (
    SELECT p.*,
        -- passer on pass plays, as "A.Daniels" (play text has "#12 A.Daniels pass ..."
        -- or "Hank Brown pass ..."; full names are shortened to match)
        CASE
            WHEN p.play_category <> 'pass' THEN NULL
            WHEN p.play_text ~ '#\d+ \S+( (Jr\.|Sr\.|II|III|IV))? (pass|sacked)'
                THEN substring(p.play_text from '#\d+ (\S+(?: (?:Jr\.|Sr\.|II|III|IV))?) (?:pass|sacked)')
            WHEN p.play_text ~ '^\S+ \S+( (Jr\.|Sr\.|II|III|IV))? (pass|sacked)'
                THEN left(p.play_text, 1) || '.'
                     || substring(p.play_text from '^\S+ (\S+(?: (?:Jr\.|Sr\.|II|III|IV))?) (?:pass|sacked)')
        END AS passer
    FROM core.plays p
    JOIN params x ON x.season = p.season AND x.conf = p.offense_conf
),
ints AS (
    SELECT * FROM plays WHERE play_type ILIKE '%intercept%'
),
int_detail AS (
    SELECT
        i.offense                                                    AS team,
        i.game_id,
        i.defense                                                    AS opponent,
        i.week,
        i.period,
        i.clock_sec,
        i.down,
        i.distance,
        i.yards_to_goal,
        i.play_type = 'Interception Return Touchdown'                AS pick_six,
        i.play_text ~* 'hurried'                                     AS qb_hurried,
        CASE WHEN i.play_text ~* 'return for (a )?loss of \d+'
                 THEN -substring(i.play_text from '(?i)return for (?:a )?loss of (\d+)')::int
             WHEN i.play_text ~* 'return \d+ yard'
                 THEN substring(i.play_text from '(?i)return (\d+) yard')::int
             ELSE 0 END                                              AS return_yards,
        i.passer,
        b.prior_plays + 1                                            AS play_in_drive,
        b.prior_passes,
        b.prior_rushes,
        b.prior_sacks,
        b.prior_yards,
        b.prior_penalties,
        b.prev_play_type = 'Sack'                                    AS right_after_sack,
        b.drive_start_ytg,
        b.start_margin
    FROM ints i
    CROSS JOIN LATERAL (
        SELECT
            count(*) FILTER (WHERE p.is_scrimmage)                                           AS prior_plays,
            count(*) FILTER (WHERE p.is_scrimmage AND p.play_category = 'pass'
                             AND p.play_type <> 'Sack')                                       AS prior_passes,
            count(*) FILTER (WHERE p.is_scrimmage AND p.play_category = 'rush')              AS prior_rushes,
            count(*) FILTER (WHERE p.play_type = 'Sack')                                      AS prior_sacks,
            coalesce(sum(p.off_yards) FILTER (WHERE p.is_scrimmage), 0)                     AS prior_yards,
            count(*) FILTER (WHERE p.play_type = 'Penalty')                                   AS prior_penalties,
            (array_agg(p.play_type ORDER BY p.play_number DESC)
                 FILTER (WHERE p.is_scrimmage))[1]                                            AS prev_play_type,
            coalesce((array_agg(p.yards_to_goal ORDER BY p.play_number)
                 FILTER (WHERE p.is_scrimmage))[1], i.yards_to_goal)                          AS drive_start_ytg,
            coalesce((array_agg(p.offense_score - p.defense_score ORDER BY p.play_number))[1],
                     i.offense_score - i.defense_score)                                       AS start_margin
        FROM plays p
        WHERE p.drive_id = i.drive_id
          AND p.offense = i.offense
          AND p.play_number < i.play_number
    ) b
),
qb_passes AS (
    -- each team's main QB: the passer with the most pass plays
    SELECT team, passer, pass_plays
    FROM (
        SELECT offense AS team, passer,
               count(*) FILTER (WHERE is_scrimmage AND play_type <> 'Sack') AS pass_plays,
               row_number() OVER (PARTITION BY offense
                                  ORDER BY count(*) FILTER (WHERE is_scrimmage AND play_type <> 'Sack') DESC,
                                           passer) AS qb_rank
        FROM plays
        WHERE passer IS NOT NULL
        GROUP BY offense, passer
    ) ranked
    WHERE qb_rank = 1
)
SELECT
    qp.team,
    qp.passer                                                        AS qb,
    qp.pass_plays,
    count(d.team)                                                    AS interceptions,
    round(100.0 * count(d.team) / NULLIF(qp.pass_plays, 0), 2)       AS ints_per_100_passes,
    count(*) FILTER (WHERE pick_six)                                 AS pick_sixes,
    round(avg(return_yards), 1)                                      AS avg_return_yards,

    -- where in the drive
    round(avg(play_in_drive), 2)                                     AS avg_play_in_drive,
    count(*) FILTER (WHERE play_in_drive = 1)                        AS on_first_play_of_drive,
    round(avg(prior_yards), 1)                                       AS avg_drive_yards_before_int,
    round(avg(prior_passes), 2)                                      AS avg_passes_before,
    round(avg(prior_rushes), 2)                                      AS avg_rushes_before,

    -- down and distance
    count(*) FILTER (WHERE down = 1)                                 AS on_1st_down,
    count(*) FILTER (WHERE down = 2)                                 AS on_2nd_down,
    count(*) FILTER (WHERE down = 3)                                 AS on_3rd_down,
    count(*) FILTER (WHERE down = 4)                                 AS on_4th_down,
    round(avg(distance), 2)                                          AS avg_yards_to_go,
    count(*) FILTER (WHERE down = 3 AND distance >= 7)               AS on_3rd_and_7_plus,

    -- pressure
    count(*) FILTER (WHERE prior_sacks > 0)                          AS sack_earlier_in_drive,
    count(*) FILTER (WHERE right_after_sack)                         AS right_after_sack,
    count(*) FILTER (WHERE qb_hurried)                               AS qb_hurried,

    -- field position
    round(avg(drive_start_ytg), 1)                                   AS avg_drive_start_yards_to_goal,
    round(avg(yards_to_goal), 1)                                     AS avg_int_yards_to_goal,
    count(*) FILTER (WHERE yards_to_goal <= 20)                      AS in_red_zone,
    count(*) FILTER (WHERE yards_to_goal > 50)                       AS in_own_territory,

    -- game situation
    count(*) FILTER (WHERE start_margin < 0)                         AS while_trailing,
    count(*) FILTER (WHERE start_margin = 0)                         AS while_tied,
    count(*) FILTER (WHERE start_margin > 0)                         AS while_leading,
    count(*) FILTER (WHERE period IN (2, 4) AND clock_sec <= 120)    AS in_two_minute,
    count(*) FILTER (WHERE period = 1)                               AS in_q1,
    count(*) FILTER (WHERE period = 2)                               AS in_q2,
    count(*) FILTER (WHERE period = 3)                               AS in_q3,
    count(*) FILTER (WHERE period = 4)                               AS in_q4,
    count(*) FILTER (WHERE period > 4)                               AS in_ot
FROM qb_passes qp
LEFT JOIN int_detail d ON d.team = qp.team AND d.passer = qp.passer   -- keeps QBs with no INTs
GROUP BY qp.team, qp.passer, qp.pass_plays
ORDER BY interceptions DESC, ints_per_100_passes DESC;

-- ---------- 2. Every interception ----------
WITH params AS (
    SELECT 2026 AS season, 'SEC' AS conf
),
plays AS (
    SELECT p.*,
        -- passer on pass plays, as "A.Daniels" (play text has "#12 A.Daniels pass ..."
        -- or "Hank Brown pass ..."; full names are shortened to match)
        CASE
            WHEN p.play_category <> 'pass' THEN NULL
            WHEN p.play_text ~ '#\d+ \S+( (Jr\.|Sr\.|II|III|IV))? (pass|sacked)'
                THEN substring(p.play_text from '#\d+ (\S+(?: (?:Jr\.|Sr\.|II|III|IV))?) (?:pass|sacked)')
            WHEN p.play_text ~ '^\S+ \S+( (Jr\.|Sr\.|II|III|IV))? (pass|sacked)'
                THEN left(p.play_text, 1) || '.'
                     || substring(p.play_text from '^\S+ (\S+(?: (?:Jr\.|Sr\.|II|III|IV))?) (?:pass|sacked)')
        END AS passer
    FROM core.plays p
    JOIN params x ON x.season = p.season AND x.conf = p.offense_conf
),
ints AS (
    SELECT * FROM plays WHERE play_type ILIKE '%intercept%'
)
SELECT
    i.offense                                                        AS team,
    i.week,
    i.defense                                                        AS opponent,
    i.passer,
    'Q' || i.period || ' ' || to_char(make_interval(secs => i.clock_sec), 'MI:SS') AS clock,
    i.down || ' & ' || i.distance                                    AS down_distance,
    i.yards_to_goal,
    b.prior_plays + 1                                                AS play_in_drive,
    b.prior_passes                                                   AS passes_before,
    b.prior_rushes                                                   AS rushes_before,
    b.prior_sacks                                                    AS sacks_before,
    b.prior_yards                                                    AS drive_yards_before,
    i.play_type = 'Interception Return Touchdown'                    AS pick_six,
    i.play_text ~* 'hurried'                                         AS qb_hurried,
    i.play_text
FROM ints i
CROSS JOIN LATERAL (
    SELECT
        count(*) FILTER (WHERE p.is_scrimmage)                                     AS prior_plays,
        count(*) FILTER (WHERE p.is_scrimmage AND p.play_category = 'pass'
                         AND p.play_type <> 'Sack')                                 AS prior_passes,
        count(*) FILTER (WHERE p.is_scrimmage AND p.play_category = 'rush')        AS prior_rushes,
        count(*) FILTER (WHERE p.play_type = 'Sack')                                AS prior_sacks,
        coalesce(sum(p.off_yards) FILTER (WHERE p.is_scrimmage), 0)               AS prior_yards
    FROM plays p
    WHERE p.drive_id = i.drive_id
      AND p.offense = i.offense
      AND p.play_number < i.play_number
) b
ORDER BY i.offense, i.week, i.period, i.clock_sec DESC;
