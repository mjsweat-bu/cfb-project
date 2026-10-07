-- =====================================================
-- core.games: one row per completed game with at least one FBS team (2004+),
-- typed from raw.api_games. game_id is the API's game ID (the same ID used by
-- core.plays, core.drives, core.team_games and core.game_lines).
-- Load raw data first:  python -m cfb.ingest_api 2004 2026
-- Safe to re-run. Drops core.team_games (built from this table); rebuild it
-- with 06_core_team_games.sql afterwards.
-- =====================================================
DROP TABLE IF EXISTS core.team_games;
DROP TABLE IF EXISTS core.games_api;    -- old name of this table
DROP TABLE IF EXISTS core.games;

CREATE TABLE core.games AS
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
    -- overtime: every line-score entry after the 4th (NULL if the game had no OT)
    (SELECT sum(x::int) FROM jsonb_array_elements_text(payload->'homeLineScores')
         WITH ORDINALITY AS t(x, i) WHERE i > 4)           AS ot_home,
    (SELECT sum(x::int) FROM jsonb_array_elements_text(payload->'awayLineScores')
         WITH ORDINALITY AS t(x, i) WHERE i > 4)           AS ot_away,

    (payload->>'excitementIndex')::numeric                 AS excitement_index,
    payload->>'notes'                                      AS notes
FROM raw.api_games
WHERE (payload->>'completed')::boolean
  AND (payload->>'homePoints') IS NOT NULL
  AND (payload->>'awayPoints') IS NOT NULL
  AND (payload->>'homeClassification' = 'fbs'
       OR payload->>'awayClassification' = 'fbs');

ALTER TABLE core.games ADD PRIMARY KEY (game_id);
CREATE INDEX ix_games_season ON core.games (season, week);
CREATE INDEX ix_games_home   ON core.games (home_team, season);
CREATE INDEX ix_games_away   ON core.games (away_team, season);

ANALYZE core.games;
