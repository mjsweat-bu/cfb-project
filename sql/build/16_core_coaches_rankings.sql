-- =====================================================
-- core.coach_seasons: one row per head coach per team per season (2000+)
-- core.poll_ranks:    one row per team per poll per week (2000+)
-- From raw.api_team_seasons (endpoints 'coaches' and 'rankings').
-- Load raw data first:  python -m cfb.ingest_api coaches_rankings 2000 2026
-- Only needs the raw tables (02), so it can run anywhere after 02. Safe to re-run.
--
-- Notes:
--   * A team-season can have two coaches (mid-season firing / interim coach);
--     wins and losses are each coach's own games.
--   * Poll weeks: week W of the regular season is the poll going INTO week W's
--     games (week 1 = preseason). Postseason week 1 is the final poll, after
--     the bowls. To get a team's rank entering a game, use the poll for that
--     game's week; for bowl games, use the last regular-season poll.
--   * Polls include 'AP Top 25', 'Coaches Poll', 'FCS Coaches Poll', and
--     'BCS Standings' / 'Playoff Committee Rankings' in the years they existed.
-- =====================================================
CREATE SCHEMA IF NOT EXISTS core;

DROP TABLE IF EXISTS core.coach_seasons;

CREATE TABLE core.coach_seasons AS
SELECT DISTINCT ON (r.season, s->>'school', coalesce(r.payload->>'id', r.record_key))
    r.season,
    s->>'school'                                     AS team,
    (s->>'teamId')::int                              AS team_id,
    s->>'conference'                                 AS conf,
    (r.payload->>'id')::int                          AS coach_id,
    (r.payload->>'firstName') || ' ' || (r.payload->>'lastName') AS coach,
    r.payload->>'firstName'                          AS first_name,
    r.payload->>'lastName'                           AS last_name,
    (r.payload->>'hireDate')::date                   AS hire_date,
    (s->>'games')::int                               AS games,
    (s->>'wins')::int                                AS wins,
    (s->>'losses')::int                              AS losses,
    (s->>'ties')::int                                AS ties,
    (s->>'preseasonRank')::int                       AS preseason_rank,
    (s->>'postseasonRank')::int                      AS postseason_rank
FROM raw.api_team_seasons r
CROSS JOIN jsonb_array_elements(r.payload->'seasons') s
WHERE r.endpoint = 'coaches'
  AND (s->>'year')::int = r.season          -- each yearly call can list a coach's other seasons too
ORDER BY r.season, s->>'school', coalesce(r.payload->>'id', r.record_key), r.fetched_at DESC;

CREATE INDEX ix_coach_seasons_coach ON core.coach_seasons (last_name, first_name);
CREATE INDEX ix_coach_seasons_team  ON core.coach_seasons (team, season);


DROP TABLE IF EXISTS core.poll_ranks;

CREATE TABLE core.poll_ranks AS
SELECT
    r.season,
    r.payload->>'seasonType'                         AS season_type,
    (r.payload->>'week')::int                        AS week,
    pl->>'poll'                                      AS poll,
    rk->>'school'                                    AS team,
    (rk->>'teamId')::int                             AS team_id,
    (rk->>'rank')::int                               AS rank,
    (rk->>'points')::int                             AS points,
    (rk->>'firstPlaceVotes')::int                    AS first_place_votes
FROM raw.api_team_seasons r
CROSS JOIN jsonb_array_elements(r.payload->'polls') pl
CROSS JOIN jsonb_array_elements(pl->'ranks') rk
WHERE r.endpoint = 'rankings';

CREATE INDEX ix_poll_ranks_lookup ON core.poll_ranks (poll, season, season_type, week, team);

ANALYZE core.coach_seasons;
ANALYZE core.poll_ranks;
