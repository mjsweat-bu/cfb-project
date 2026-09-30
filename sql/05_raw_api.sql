CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE IF NOT EXISTS raw.api_games (
    source_id   text PRIMARY KEY,   -- the API's own game ID
    season      integer NOT NULL,
    payload     jsonb NOT NULL,
    first_seen  timestamptz NOT NULL DEFAULT now(),
    fetched_at  timestamptz NOT NULL DEFAULT now()
);

-- Season-level endpoints (stats/season, stats/season/advanced, records).
-- record_key identifies a record within (endpoint, season):
--   stats/season          -> team|statName  (API returns one row per stat)
--   stats/season/advanced -> team
--   records               -> teamId
CREATE TABLE IF NOT EXISTS raw.api_team_seasons (
    endpoint    text    NOT NULL,
    season      integer NOT NULL,
    record_key  text    NOT NULL,
    payload     jsonb   NOT NULL,
    first_seen  timestamptz NOT NULL DEFAULT now(),
    fetched_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (endpoint, season, record_key)
);

-- Player season endpoints. record_key = playerId|team for all of them:
--   stats/player/season -> one record per player, stats grouped by the loader
--                          as {"passing": {"ATT": "448", ...}, ...}
--   player/usage, ppa/players/season, roster -> API record as-is
CREATE TABLE IF NOT EXISTS raw.api_player_seasons (
    endpoint    text    NOT NULL,
    season      integer NOT NULL,
    record_key  text    NOT NULL,
    payload     jsonb   NOT NULL,
    first_seen  timestamptz NOT NULL DEFAULT now(),
    fetched_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (endpoint, season, record_key)
);

CREATE TABLE IF NOT EXISTS raw.ingest_log (
    run_at   timestamptz DEFAULT now(),
    endpoint text,
    season   integer,
    rows     integer,
    status   text
);
