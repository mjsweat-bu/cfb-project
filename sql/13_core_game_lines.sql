-- =====================================================
-- Betting lines from raw.api_lines (/lines). The API has lines from 2013 on;
-- earlier games come back with an empty lines array and are dropped.
-- Load raw data first:  python src\ingest_api.py lines 2004 2026
-- Safe to re-run.
--
-- core.game_lines   one row per game per provider (consensus, Bovada, DraftKings, ...)
-- core.game_spreads one row per game: the consensus line if the API has one,
--                   otherwise the median across providers
--
-- Spreads are from the home team's side: -7 = home favored by 7.
--   ats_result  'home' / 'away' / 'push': who covered (home_score + spread vs away_score)
--   ou_result   'over' / 'under' / 'push'
-- Both are NULL until the game has a final score.
-- =====================================================
CREATE SCHEMA IF NOT EXISTS core;

DROP TABLE IF EXISTS core.game_spreads;
DROP TABLE IF EXISTS core.game_lines;

CREATE TABLE core.game_lines AS
WITH l AS (
    SELECT
        g.source_id::bigint                                AS game_id,
        g.season,
        g.payload->>'seasonType'                           AS season_type,
        (g.payload->>'week')::int                          AS week,
        (g.payload->>'startDate')::timestamptz             AS start_date,
        g.payload->>'homeTeam'                             AS home_team,
        g.payload->>'homeConference'                       AS home_conf,
        g.payload->>'homeClassification'                   AS home_class,
        g.payload->>'awayTeam'                             AS away_team,
        g.payload->>'awayConference'                       AS away_conf,
        g.payload->>'awayClassification'                   AS away_class,
        (g.payload->>'homeScore')::int                     AS home_score,
        (g.payload->>'awayScore')::int                     AS away_score,
        x->>'provider'                                     AS provider,
        (x->>'spread')::numeric                            AS spread,
        (x->>'spreadOpen')::numeric                        AS spread_open,
        (x->>'overUnder')::numeric                         AS over_under,
        (x->>'overUnderOpen')::numeric                     AS over_under_open,
        (x->>'homeMoneyline')::int                         AS home_moneyline,
        (x->>'awayMoneyline')::int                         AS away_moneyline,
        x->>'formattedSpread'                              AS formatted_spread
    FROM raw.api_lines g
    CROSS JOIN jsonb_array_elements(g.payload->'lines') x
)
SELECT
    l.*,
    home_score - away_score                                AS home_margin,
    home_score + away_score                                AS total_points,
    CASE WHEN home_score + spread > away_score THEN 'home'
         WHEN home_score + spread < away_score THEN 'away'
         WHEN home_score + spread = away_score THEN 'push' END AS ats_result,
    CASE WHEN home_score + away_score > over_under THEN 'over'
         WHEN home_score + away_score < over_under THEN 'under'
         WHEN home_score + away_score = over_under THEN 'push' END AS ou_result
FROM l;

ALTER TABLE core.game_lines ADD PRIMARY KEY (game_id, provider);
CREATE INDEX ON core.game_lines (season, week);


CREATE TABLE core.game_spreads AS
WITH agg AS (
    SELECT
        game_id,
        count(*)                                                        AS n_providers,
        max(spread)          FILTER (WHERE provider = 'consensus')      AS consensus_spread,
        max(over_under)      FILTER (WHERE provider = 'consensus')      AS consensus_over_under,
        max(home_moneyline)  FILTER (WHERE provider = 'consensus')      AS consensus_home_ml,
        max(away_moneyline)  FILTER (WHERE provider = 'consensus')      AS consensus_away_ml,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY spread)             AS median_spread,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY over_under)         AS median_over_under,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY home_moneyline)     AS median_home_ml,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY away_moneyline)     AS median_away_ml,
        min(spread)                                                     AS min_spread,
        max(spread)                                                     AS max_spread
    FROM core.game_lines
    GROUP BY game_id
),
g AS (
    SELECT DISTINCT ON (game_id)
        game_id, season, season_type, week, start_date,
        home_team, home_conf, home_class, away_team, away_conf, away_class,
        home_score, away_score, home_margin, total_points
    FROM core.game_lines
)
SELECT
    g.*,
    a.n_providers,
    CASE WHEN a.consensus_spread IS NOT NULL THEN 'consensus' ELSE 'median' END AS line_source,
    coalesce(a.consensus_spread, a.median_spread::numeric)               AS spread,
    coalesce(a.consensus_over_under, a.median_over_under::numeric)       AS over_under,
    coalesce(a.consensus_home_ml, a.median_home_ml::int)                 AS home_moneyline,
    coalesce(a.consensus_away_ml, a.median_away_ml::int)                 AS away_moneyline,
    a.max_spread - a.min_spread                                          AS spread_range
FROM g
JOIN agg a USING (game_id);

ALTER TABLE core.game_spreads ADD PRIMARY KEY (game_id);

-- same result columns as core.game_lines, from the chosen line
ALTER TABLE core.game_spreads
    ADD COLUMN ats_result text,
    ADD COLUMN ou_result  text;
UPDATE core.game_spreads SET
    ats_result = CASE WHEN home_score + spread > away_score THEN 'home'
                      WHEN home_score + spread < away_score THEN 'away'
                      WHEN home_score + spread = away_score THEN 'push' END,
    ou_result  = CASE WHEN total_points > over_under THEN 'over'
                      WHEN total_points < over_under THEN 'under'
                      WHEN total_points = over_under THEN 'push' END;

ANALYZE core.game_lines;
ANALYZE core.game_spreads;
