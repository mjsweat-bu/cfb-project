-- Team offense and defense by conference and season: PPA (predicted points added,
-- the API's name for EPA) per play, split by pass/rush, with success rate,
-- explosiveness, strength of schedule and opponent-adjusted PPA.
-- Change the season, conference or minimum plays in `params`.
-- Source: core.plays, scrimmage plays only (down 1-4, run or pass; penalties,
-- kicks and 2-pt tries excluded; sacks count as pass plays).
-- Notes:
--   * PPA = expected points after the play minus before it. ~0 is an average
--     play; +0.25/play or better is an elite offense. The FBS average has drifted
--     up over time (~0.05 in 2005-09, ~0.12 in the 2020s), so compare within a season.
--   * Garbage time is excluded: score margin > 38 in Q2, > 28 in Q3, > 22 in Q4.
--   * explosiveness = average PPA on successful plays only (is_success), the
--     "how big" to success rate's "how often".
--   * Offense columns (no prefix): HIGHER is better. Defense columns (def_):
--     PPA, success and explosiveness ALLOWED, so LOWER is better.
--   * Strength of schedule uses each opponent's season average over all FBS
--     games, leaving out its plays against the team being rated so a team's own
--     results don't grade its schedule. FCS and other opponents with fewer than
--     `min_opp_plays` other plays get the FBS average.
--       sos_def_ppa_allowed  offense: opponents' defensive PPA allowed per play;
--                            LOWER = tougher defenses faced
--       def_sos_off_ppa      defense: opponents' offensive PPA per play;
--                            HIGHER = tougher offenses faced
--       sos_vs_avg / def_sos_vs_avg  the above minus the FBS average
--       sos_rank / def_sos_rank      1 = toughest schedule in the conference
--   * Adjusted PPA = average of (play PPA - what the opponent usually allows/gains)
--     + FBS average, i.e. PPA per play against an average opponent. Pass/rush
--     versions use the opponent's pass/rush averages.
--   * adj_net_ppa = adj_ppa_per_play - def_adj_ppa_per_play: points per play
--     better than an average team, offense and defense combined.
WITH params AS (
    SELECT 2026 AS season, 'SEC' AS conf, 100 AS min_plays, 150 AS min_opp_plays
),
season_plays AS (
    -- every team's plays this season, for the opponent baselines
    SELECT p.*
    FROM core.plays p
    JOIN params x ON x.season = p.season
    WHERE p.is_scrimmage
      AND p.ppa IS NOT NULL
      AND NOT (   (p.period = 2 AND abs(p.offense_score - p.defense_score) > 38)
               OR (p.period = 3 AND abs(p.offense_score - p.defense_score) > 28)
               OR (p.period = 4 AND abs(p.offense_score - p.defense_score) > 22))
),
fbs_avg AS (
    SELECT avg(ppa)                                           AS ppa,
           avg(ppa) FILTER (WHERE play_category = 'pass')     AS pass_ppa,
           avg(ppa) FILTER (WHERE play_category = 'rush')     AS rush_ppa
    FROM season_plays
),
pair_totals AS (
    -- totals for each offense against each defense
    SELECT defense, offense,
           count(*) AS n, sum(ppa) AS ppa,
           count(*) FILTER (WHERE play_category = 'pass') AS pass_n,
           coalesce(sum(ppa) FILTER (WHERE play_category = 'pass'), 0) AS pass_ppa,
           count(*) FILTER (WHERE play_category = 'rush') AS rush_n,
           coalesce(sum(ppa) FILTER (WHERE play_category = 'rush'), 0) AS rush_ppa
    FROM season_plays
    GROUP BY defense, offense
),
def_totals AS (
    SELECT defense, sum(n) AS n, sum(ppa) AS ppa, sum(pass_n) AS pass_n,
           sum(pass_ppa) AS pass_ppa, sum(rush_n) AS rush_n, sum(rush_ppa) AS rush_ppa
    FROM pair_totals
    GROUP BY defense
),
off_totals AS (
    SELECT offense, sum(n) AS n, sum(ppa) AS ppa, sum(pass_n) AS pass_n,
           sum(pass_ppa) AS pass_ppa, sum(rush_n) AS rush_n, sum(rush_ppa) AS rush_ppa
    FROM pair_totals
    GROUP BY offense
),
baselines AS (
    -- for each offense/defense pair:
    --   allowed* = the defense's PPA allowed per play, excluding this offense
    --   gained*  = the offense's PPA gained per play, excluding this defense
    SELECT pt.defense, pt.offense,
           CASE WHEN d.n - pt.n >= x.min_opp_plays
                THEN (d.ppa - pt.ppa) / (d.n - pt.n) ELSE f.ppa END                AS allowed,
           CASE WHEN d.pass_n - pt.pass_n >= x.min_opp_plays / 2
                THEN (d.pass_ppa - pt.pass_ppa) / (d.pass_n - pt.pass_n) ELSE f.pass_ppa END AS pass_allowed,
           CASE WHEN d.rush_n - pt.rush_n >= x.min_opp_plays / 2
                THEN (d.rush_ppa - pt.rush_ppa) / (d.rush_n - pt.rush_n) ELSE f.rush_ppa END AS rush_allowed,
           CASE WHEN o.n - pt.n >= x.min_opp_plays
                THEN (o.ppa - pt.ppa) / (o.n - pt.n) ELSE f.ppa END                AS gained,
           CASE WHEN o.pass_n - pt.pass_n >= x.min_opp_plays / 2
                THEN (o.pass_ppa - pt.pass_ppa) / (o.pass_n - pt.pass_n) ELSE f.pass_ppa END AS pass_gained,
           CASE WHEN o.rush_n - pt.rush_n >= x.min_opp_plays / 2
                THEN (o.rush_ppa - pt.rush_ppa) / (o.rush_n - pt.rush_n) ELSE f.rush_ppa END AS rush_gained
    FROM pair_totals pt
    JOIN def_totals d USING (defense)
    JOIN off_totals o USING (offense)
    CROSS JOIN params x
    CROSS JOIN fbs_avg f
),
plays AS (
    SELECT p.*, b.allowed, b.pass_allowed, b.rush_allowed,
           b.gained, b.pass_gained, b.rush_gained
    FROM season_plays p
    JOIN baselines b USING (defense, offense)
),
offense AS (
    SELECT
        offense                                                         AS team,
        count(DISTINCT game_id)                                         AS games,
        count(*)                                                        AS plays,
        round(avg(ppa), 3)                                              AS ppa_per_play,
        round(sum(ppa), 1)                                              AS total_ppa,
        count(*) FILTER (WHERE play_category = 'pass')                  AS pass_plays,
        round(avg(ppa) FILTER (WHERE play_category = 'pass'), 3)        AS pass_ppa,
        count(*) FILTER (WHERE play_category = 'rush')                  AS rush_plays,
        round(avg(ppa) FILTER (WHERE play_category = 'rush'), 3)        AS rush_ppa,
        round(avg(is_success::int) * 100, 1)                            AS success_pct,
        round(avg(ppa) FILTER (WHERE is_success), 3)                    AS explosiveness,

        -- strength of schedule and opponent adjustment
        round(avg(allowed), 3)                                          AS sos_def_ppa_allowed,
        round(avg(allowed) - (SELECT ppa FROM fbs_avg), 3)              AS sos_vs_avg,
        round(avg(ppa - allowed) + (SELECT ppa FROM fbs_avg), 3)        AS adj_ppa_per_play,
        round(avg(ppa - pass_allowed) FILTER (WHERE play_category = 'pass')
              + (SELECT pass_ppa FROM fbs_avg), 3)                      AS adj_pass_ppa,
        round(avg(ppa - rush_allowed) FILTER (WHERE play_category = 'rush')
              + (SELECT rush_ppa FROM fbs_avg), 3)                      AS adj_rush_ppa
    FROM plays
    WHERE offense_conf = (SELECT conf FROM params)
    GROUP BY offense
    HAVING count(*) >= (SELECT min_plays FROM params)
),
defense AS (
    SELECT
        defense                                                         AS team,
        count(*)                                                        AS def_plays,
        round(avg(ppa), 3)                                              AS def_ppa_per_play,
        round(sum(ppa), 1)                                              AS def_total_ppa,
        round(avg(ppa) FILTER (WHERE play_category = 'pass'), 3)        AS def_pass_ppa,
        round(avg(ppa) FILTER (WHERE play_category = 'rush'), 3)        AS def_rush_ppa,
        round(avg(is_success::int) * 100, 1)                            AS def_success_pct,
        round(avg(ppa) FILTER (WHERE is_success), 3)                    AS def_explosiveness,

        -- strength of schedule and opponent adjustment
        round(avg(gained), 3)                                           AS def_sos_off_ppa,
        round(avg(gained) - (SELECT ppa FROM fbs_avg), 3)               AS def_sos_vs_avg,
        round(avg(ppa - gained) + (SELECT ppa FROM fbs_avg), 3)         AS def_adj_ppa_per_play,
        round(avg(ppa - pass_gained) FILTER (WHERE play_category = 'pass')
              + (SELECT pass_ppa FROM fbs_avg), 3)                      AS def_adj_pass_ppa,
        round(avg(ppa - rush_gained) FILTER (WHERE play_category = 'rush')
              + (SELECT rush_ppa FROM fbs_avg), 3)                      AS def_adj_rush_ppa
    FROM plays
    WHERE defense_conf = (SELECT conf FROM params)
    GROUP BY defense
    HAVING count(*) >= (SELECT min_plays FROM params)
)
SELECT
    team, o.games,
    adj_ppa_per_play - def_adj_ppa_per_play                             AS adj_net_ppa,
    rank() OVER (ORDER BY adj_ppa_per_play - def_adj_ppa_per_play DESC) AS net_rank,

    -- offense (higher is better)
    o.plays,
    ppa_per_play, adj_ppa_per_play,
    rank() OVER (ORDER BY ppa_per_play DESC)                            AS raw_rank,
    rank() OVER (ORDER BY adj_ppa_per_play DESC)                        AS adj_rank,
    sos_def_ppa_allowed, sos_vs_avg,
    rank() OVER (ORDER BY sos_def_ppa_allowed)                          AS sos_rank,
    total_ppa,
    pass_plays, pass_ppa, adj_pass_ppa,
    rush_plays, rush_ppa, adj_rush_ppa,
    success_pct, explosiveness,

    -- defense (PPA allowed: lower is better)
    def_plays,
    def_ppa_per_play, def_adj_ppa_per_play,
    rank() OVER (ORDER BY def_ppa_per_play)                             AS def_raw_rank,
    rank() OVER (ORDER BY def_adj_ppa_per_play)                         AS def_adj_rank,
    def_sos_off_ppa, def_sos_vs_avg,
    rank() OVER (ORDER BY def_sos_off_ppa DESC)                         AS def_sos_rank,
    def_total_ppa,
    def_pass_ppa, def_adj_pass_ppa,
    def_rush_ppa, def_adj_rush_ppa,
    def_success_pct, def_explosiveness
FROM offense o
JOIN defense d USING (team)
ORDER BY adj_net_ppa DESC;
