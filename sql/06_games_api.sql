-- =====================================================
-- core.games_api: typed games built from raw.api_games
-- Keeps games where at least one team is FBS and the game is completed.
-- Safe to re-run.
-- =====================================================
DROP TABLE IF EXISTS core.games_api;

CREATE TABLE core.games_api AS
SELECT
    (payload->>'id')::bigint                               AS game_id,
    (payload->>'season')::int                              AS season,
    (payload->>'week')::int                                AS week,
    payload->>'seasonType'                                 AS season_type,
    (payload->>'startDate')::timestamptz                   AS start_ts,
    ((payload->>'startDate')::timestamptz
        AT TIME ZONE 'America/New_York')::date             AS game_date,
    (payload->>'startTimeTBD')::boolean                    AS start_time_tbd,
    (payload->>'neutralSite')::boolean                     AS is_neutral,
    (payload->>'conferenceGame')::boolean                  AS is_conf_game,
    (payload->>'attendance')::int                          AS attendance,
    payload->>'venue'                                      AS venue,

    (payload->>'homeId')::int                              AS home_id,
    payload->>'homeTeam'                                   AS home_team,
    payload->>'homeClassification'                         AS home_class,
    payload->>'homeConference'                             AS home_conf,
    (payload->>'homePoints')::int                          AS score_home,
    (payload->>'homePregameElo')::int                      AS home_pregame_elo,

    (payload->>'awayId')::int                              AS away_id,
    payload->>'awayTeam'                                   AS away_team,
    payload->>'awayClassification'                         AS away_class,
    payload->>'awayConference'                             AS away_conf,
    (payload->>'awayPoints')::int                          AS score_away,
    (payload->>'awayPregameElo')::int                      AS away_pregame_elo,

    -- line scores: [q1, q2, q3, q4, (ot...)]
    (payload->'homeLineScores'->>0)::int AS q1_home,
    (payload->'homeLineScores'->>1)::int AS q2_home,
    (payload->'homeLineScores'->>2)::int AS q3_home,
    (payload->'homeLineScores'->>3)::int AS q4_home,
    (payload->'awayLineScores'->>0)::int AS q1_away,
    (payload->'awayLineScores'->>1)::int AS q2_away,
    (payload->'awayLineScores'->>2)::int AS q3_away,
    (payload->'awayLineScores'->>3)::int AS q4_away,

    (payload->>'excitementIndex')::numeric                 AS excitement_index,
    payload->>'notes'                                      AS notes
FROM raw.api_games
WHERE (payload->>'completed')::boolean
  AND (payload->>'homePoints') IS NOT NULL
  AND (payload->>'awayPoints') IS NOT NULL
  AND (payload->>'homeClassification' = 'fbs'
       OR payload->>'awayClassification' = 'fbs');

ALTER TABLE core.games_api ADD PRIMARY KEY (game_id);
CREATE INDEX ix_games_api_season ON core.games_api (season, week);
CREATE INDEX ix_games_api_home   ON core.games_api (home_team, season);
CREATE INDEX ix_games_api_away   ON core.games_api (away_team, season);