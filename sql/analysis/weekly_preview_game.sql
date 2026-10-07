-- Weekly preview: the team's next game after `week` (skips bye weeks), with the
-- betting line if the API has one yet. Change team / season / week in `params`.
-- "Next" = the first game after `week`, played or not, so past weeks and past
-- seasons can be previewed too.
-- Source: raw.api_games (the schedule; core.games only has completed games),
-- core.game_spreads (consensus or median across books).
-- team_spread: -7 = the team is favored by 7. Returns no row after the last game.
-- Postseason games count as after every regular-season week.
WITH params AS (
    SELECT 'Auburn'::text AS team, 2026 AS season, 5 AS week
),
nxt AS (
    SELECT
        (r.payload->>'id')::bigint                                   AS game_id,
        (r.payload->>'week')::int                                    AS week,
        r.payload->>'seasonType'                                     AS season_type,
        ((r.payload->>'startDate')::timestamptz
            AT TIME ZONE 'America/New_York')                         AS kickoff_et,
        (r.payload->>'startTimeTBD')::boolean                        AS time_tbd,
        r.payload->>'homeTeam'                                       AS home_team,
        r.payload->>'awayTeam'                                       AS away_team,
        (r.payload->>'neutralSite')::boolean                         AS is_neutral,
        r.payload->>'venue'                                          AS venue
    FROM raw.api_games r
    JOIN params x ON x.season = r.season
    WHERE x.team IN (r.payload->>'homeTeam', r.payload->>'awayTeam')
      AND ((r.payload->>'seasonType') = 'postseason' OR (r.payload->>'week')::int > x.week)
    ORDER BY (r.payload->>'startDate')::timestamptz
    LIMIT 1
)
SELECT
    n.game_id,
    n.week,
    n.season_type,
    CASE WHEN n.time_tbd THEN to_char(n.kickoff_et, 'Dy Mon DD') || ', time TBD'
         ELSE to_char(n.kickoff_et, 'Dy Mon DD, HH12:MI AM') || ' ET' END AS kickoff,
    CASE WHEN n.is_neutral          THEN 'neutral'
         WHEN n.home_team = x.team  THEN 'home'
         ELSE 'away' END                                             AS site,
    CASE WHEN n.home_team = x.team THEN n.away_team ELSE n.home_team END AS opponent,
    n.venue,
    CASE WHEN n.home_team = x.team THEN s.spread ELSE -s.spread END  AS team_spread,
    s.over_under,
    s.n_providers                                                    AS books
FROM nxt n
CROSS JOIN params x
LEFT JOIN core.game_spreads s ON s.game_id = n.game_id;
