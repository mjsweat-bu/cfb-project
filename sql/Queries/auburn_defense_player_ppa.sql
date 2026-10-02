-- Defensive players for one team and season: the PPA (predicted points added,
-- the API's name for EPA) of the plays each defender made, plus tackles,
-- tackles for loss, stops, sacks, interceptions, pass breakups, hurries and
-- forced/recovered fumbles.
-- Change the season, team or minimum plays in `params`.
-- Source: core.plays (scrimmage plays, garbage time excluded as in
-- sec_team_ppa.sql), raw.api_player_seasons roster for full name and position.
-- Notes:
--   * The API has no defensive player PPA and /plays/stats has no tackles, so
--     defenders are parsed from play_text in the ESPN format, e.g.
--       "... for 6 yards gain to the BAY31 (#17 X.Atkins; #1 C.Anthony)"
--       "... pass incomplete ... broken up by #8 K.Harris"
--     Games in other text formats (e.g. Auburn's 2025 weeks 1-8, which list only
--     sackers and interceptors by full name) aren't picked up. Check `games` per
--     player against the team's schedule.
--   * Tacklers = names in parentheses, except on interceptions and lost fumbles
--     where the parentheses hold the offensive player who made the tackle.
--   * PPA here is the OFFENSE's PPA on the play, so LOWER is better for the
--     defender. vs_team_avg = avg_ppa minus the team's PPA allowed per play on
--     all its defensive plays (negative = the defender's plays went better than
--     the defense's average play).
--   * Tackle PPA is biased by position: linemen and linebackers tackle near the
--     line, while safeties often make the tackle after a completed pass or long
--     run has already gained yards. Compare players within a position group, and
--     use stop_pct / tfl / havoc_plays alongside avg_ppa.
--   * stop = a tackle on a play the offense did not "succeed" on (is_success:
--     50% of distance on 1st down, 70% on 2nd, 100% on 3rd/4th).
--   * havoc_plays = plays with a tackle for loss, sack, interception, pass
--     breakup or forced fumble.
WITH params AS (
    SELECT 2026 AS season, 'Auburn' AS team, 5 AS min_plays
),
plays AS (
    SELECT p.*
    FROM core.plays p
    JOIN params x ON x.season = p.season AND x.team = p.defense
    WHERE p.is_scrimmage
      AND p.ppa IS NOT NULL
      AND NOT (   (p.period = 2 AND abs(p.offense_score - p.defense_score) > 38)
               OR (p.period = 3 AND abs(p.offense_score - p.defense_score) > 28)
               OR (p.period = 4 AND abs(p.offense_score - p.defense_score) > 22))
),
team_avg AS (
    SELECT avg(ppa) AS ppa FROM plays
),
credits AS (
    -- tacklers: "(#17 X.Atkins; #1 C.Anthony)"
    SELECT p.play_id,
           substring(t.s FROM '#(\d+)')::int                          AS jersey,
           btrim(replace(substring(t.s FROM '#\d+\s+(.*)$'), ',', ''))  AS name,
           CASE WHEN p.play_type = 'Sack' THEN 'sack' ELSE 'tackle' END AS kind,
           length(g[1]) - length(replace(g[1], '#', ''))              AS n_tacklers
    FROM plays p
    CROSS JOIN LATERAL regexp_matches(p.play_text, '\(([^()]*#\d+[^()]*)\)', 'g') g
    -- tacklers are separated by ";" or "," (split only before a "#", so "W.Mathis, Jr." stays whole)
    CROSS JOIN LATERAL regexp_split_to_table(g[1], '[;,]\s*(?=#)') t(s)
    WHERE p.play_type NOT ILIKE '%interception%'
      AND p.play_type <> 'Fumble Recovery (Opponent)'
      AND t.s ~ '#\d+'
      AND g[1] !~ '(H:|LS:|blocked)'      -- extra-point holder / long snapper, kick blockers

    UNION ALL
    -- "intercepted by", "broken up by", "hurried by", "forced by" (fumble)
    SELECT p.play_id,
           m[2]::int,
           replace(m[3], ',', ''),
           CASE m[1] WHEN 'intercepted' THEN 'int'   WHEN 'broken up' THEN 'pbu'
                     WHEN 'hurried'     THEN 'hurry' WHEN 'forced'    THEN 'ff' END,
           NULL
    FROM plays p
    CROSS JOIN LATERAL regexp_matches(p.play_text,
        '(intercepted|broken up|hurried|forced) by #(\d+) ([A-Z][^ ,;()]*(?:,? (?:Jr\.|Sr\.|II|III|IV))?)', 'g') m

    UNION ALL
    -- lost fumbles: "recovered by AUB #8 K.Harris"
    SELECT p.play_id,
           m[1]::int,
           replace(m[2], ',', ''),
           'fr',
           NULL
    FROM plays p
    CROSS JOIN LATERAL regexp_matches(p.play_text,
        'recovered by \S+ #(\d+) ([A-Z][^ ,;()]*(?:,? (?:Jr\.|Sr\.|II|III|IV))?)', 'g') m
    WHERE p.play_type = 'Fumble Recovery (Opponent)'
),
player_plays AS (
    -- one row per defender per play
    SELECT c.jersey, c.name, c.play_id,
           bool_or(c.kind IN ('tackle', 'sack'))                AS tackle,
           bool_or(c.kind IN ('tackle', 'sack') AND c.n_tacklers = 1) AS solo,
           bool_or(c.kind = 'sack')                             AS sack,
           bool_or(c.kind = 'int')                              AS int,
           bool_or(c.kind = 'pbu')                              AS pbu,
           bool_or(c.kind = 'hurry')                            AS hurry,
           bool_or(c.kind = 'ff')                               AS ff,
           bool_or(c.kind = 'fr')                               AS fr
    FROM credits c
    GROUP BY c.jersey, c.name, c.play_id
),
players AS (
    SELECT
        pp.jersey, pp.name,
        count(DISTINCT p.game_id)                                           AS games,
        count(*)                                                            AS plays,
        round(avg(p.ppa), 3)                                                AS avg_ppa,
        round(avg(p.ppa) - (SELECT ppa FROM team_avg), 3)                   AS vs_team_avg,

        count(*) FILTER (WHERE tackle)                                      AS tackles,
        count(*) FILTER (WHERE solo)                                        AS solo_tackles,
        round(avg(p.ppa) FILTER (WHERE tackle), 3)                          AS tackle_avg_ppa,
        count(*) FILTER (WHERE tackle AND p.play_category = 'rush')         AS run_tackles,
        round(avg(p.ppa) FILTER (WHERE tackle AND p.play_category = 'rush'), 3) AS run_tackle_avg_ppa,
        count(*) FILTER (WHERE tackle AND p.play_category = 'pass')         AS pass_tackles,
        round(avg(p.ppa) FILTER (WHERE tackle AND p.play_category = 'pass'), 3) AS pass_tackle_avg_ppa,
        count(*) FILTER (WHERE tackle AND p.off_yards < 0)                  AS tfl,
        count(*) FILTER (WHERE tackle AND NOT p.is_success)                 AS stops,
        round(avg((NOT p.is_success)::int) FILTER (WHERE tackle) * 100, 1)  AS stop_pct,

        count(*) FILTER (WHERE sack)                                        AS sacks,
        count(*) FILTER (WHERE int)                                         AS ints,
        count(*) FILTER (WHERE pbu)                                         AS pbus,
        count(*) FILTER (WHERE hurry)                                       AS hurries,
        count(*) FILTER (WHERE ff)                                          AS forced_fumbles,
        count(*) FILTER (WHERE fr)                                          AS fumble_recoveries,
        count(*) FILTER (WHERE (tackle AND p.off_yards < 0) OR sack OR int OR pbu OR ff) AS havoc_plays,
        round(avg(p.ppa) FILTER (WHERE (tackle AND p.off_yards < 0) OR sack OR int OR pbu OR ff), 3) AS havoc_avg_ppa
    FROM player_plays pp
    JOIN plays p USING (play_id)
    GROUP BY pp.jersey, pp.name
    HAVING count(*) >= (SELECT min_plays FROM params)
)
SELECT
    coalesce(r.payload->>'firstName' || ' ' || (r.payload->>'lastName'), pl.name) AS player,
    pl.jersey,
    r.payload->>'position'                                                      AS pos,
    pl.games, pl.plays, pl.avg_ppa, pl.vs_team_avg,
    pl.tackles, pl.solo_tackles, pl.tackle_avg_ppa,
    pl.run_tackles, pl.run_tackle_avg_ppa, pl.pass_tackles, pl.pass_tackle_avg_ppa,
    pl.tfl, pl.stops, pl.stop_pct,
    pl.sacks, pl.ints, pl.pbus, pl.hurries, pl.forced_fumbles, pl.fumble_recoveries,
    pl.havoc_plays, pl.havoc_avg_ppa
FROM players pl
CROSS JOIN params x
LEFT JOIN LATERAL (
    -- match the roster on last name + jersey (jersey numbers repeat across
    -- offense/defense); if the jersey differs from the roster's, fall back
    -- to last name + first initial
    SELECT payload
    FROM raw.api_player_seasons r
    WHERE r.endpoint = 'roster'
      AND r.season = x.season
      AND r.payload->>'team' = x.team
      AND lower(pl.name) LIKE '%' || lower(split_part(r.payload->>'lastName', ' ', 1)) || '%'
      AND (   (r.payload->>'jersey')::int = pl.jersey
           OR upper(left(r.payload->>'firstName', 1)) = upper(left(pl.name, 1)))
    ORDER BY ((r.payload->>'jersey')::int = pl.jersey) DESC
    LIMIT 1
) r ON true
ORDER BY pl.plays DESC;
