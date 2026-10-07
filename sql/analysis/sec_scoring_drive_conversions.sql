-- 3rd- and 4th-down conversions on scoring vs non-scoring drives, by team,
-- plus a conference-wide row. Change the season or conference in `params`.
-- Source: core.drives.
-- Definitions:
--   * Drive: a team's drive with at least one scrimmage play (the API also
--     files kickoffs as the kicking team's own "drive").
--   * Scoring drive: contains an offensive touchdown or a made field goal.
--     Defensive and return scores (pick-sixes, punt-return TDs, safeties) don't count.
--     Some TDs are typed 'Rush' / 'Pass Reception' with scoring = true, so
--     those are included.
--   * Attempt: a scrimmage play on 3rd or 4th down (punts and field goal tries
--     aren't scrimmage plays, so 4th-down attempts are go-for-it plays).
--   * Conversion: yards gained >= distance (a TD on 3rd/4th down counts).
--     First downs by penalty are not counted.
WITH params AS (
    SELECT 2026 AS season, 'SEC' AS conf
),
drives AS (
    SELECT
        d.offense                                                       AS team,
        d.drive_id,
        CASE WHEN d.result IN ('TD', 'FG') THEN d.result ELSE 'none' END AS result,
        d.third_att,
        d.third_conv,
        d.fourth_att,
        d.fourth_conv
    FROM core.drives d
    JOIN params x ON x.season = d.season AND x.conf = d.offense_conf
    WHERE d.plays > 0
)
SELECT
    coalesce(team, '** ' || (SELECT conf FROM params) || ' total **')  AS team,

    -- ---------- drives ----------
    count(*)                                                            AS drives,
    count(*) FILTER (WHERE result <> 'none')                            AS scoring_drives,
    count(*) FILTER (WHERE result = 'TD')                               AS td_drives,
    count(*) FILTER (WHERE result = 'FG')                               AS fg_drives,
    round(avg((result <> 'none')::int), 3)                              AS scoring_drive_rate,

    -- ---------- conversions on scoring drives ----------
    sum(third_att)   FILTER (WHERE result <> 'none')                    AS sd_third_att,
    sum(third_conv)  FILTER (WHERE result <> 'none')                    AS sd_third_conv,
    round(sum(third_conv)  FILTER (WHERE result <> 'none')::numeric
        / NULLIF(sum(third_att)  FILTER (WHERE result <> 'none'), 0), 3) AS sd_third_conv_rate,
    sum(fourth_att)  FILTER (WHERE result <> 'none')                    AS sd_fourth_att,
    sum(fourth_conv) FILTER (WHERE result <> 'none')                    AS sd_fourth_conv,
    round(avg(third_conv + fourth_conv) FILTER (WHERE result <> 'none'), 2)  AS sd_conversions_per_drive,
    round(avg(third_conv + fourth_conv) FILTER (WHERE result = 'TD'), 2)     AS td_drive_conversions_per_drive,
    round(avg(third_conv + fourth_conv) FILTER (WHERE result = 'FG'), 2)     AS fg_drive_conversions_per_drive,
    round(avg((third_conv + fourth_conv > 0)::int) FILTER (WHERE result <> 'none'), 3)
                                                                        AS sd_pct_needing_a_conversion,
    round(avg((third_att = 0)::int) FILTER (WHERE result <> 'none'), 3) AS sd_pct_no_third_down_faced,

    -- ---------- conversions on non-scoring drives ----------
    sum(third_att)   FILTER (WHERE result = 'none')                     AS nsd_third_att,
    sum(third_conv)  FILTER (WHERE result = 'none')                     AS nsd_third_conv,
    round(sum(third_conv)  FILTER (WHERE result = 'none')::numeric
        / NULLIF(sum(third_att)  FILTER (WHERE result = 'none'), 0), 3) AS nsd_third_conv_rate,
    sum(fourth_att)  FILTER (WHERE result = 'none')                     AS nsd_fourth_att,
    sum(fourth_conv) FILTER (WHERE result = 'none')                     AS nsd_fourth_conv,
    round(avg(third_conv + fourth_conv) FILTER (WHERE result = 'none'), 2)   AS nsd_conversions_per_drive
FROM drives
GROUP BY ROLLUP (team)
ORDER BY (team IS NULL), sd_conversions_per_drive DESC;
