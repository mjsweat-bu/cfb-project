-- =====================================================
-- marts.game_features: one row per game, pre-game features only
-- Every feature uses window frames that END at "1 PRECEDING",
-- so the current game is never included.
-- Sources: core.games (03), core.team_games (06), marts.team_season_stats (09,
-- prior season; FBS teams only, so FCS teams get NULL), core.game_spreads (08,
-- closing line, 2013+).
-- Box-score features average only prior games with stats; PPA features only
-- prior games with play-by-play.
-- Safe to re-run.
-- =====================================================
DROP TABLE IF EXISTS marts.game_features;

CREATE TABLE marts.game_features AS
WITH pre AS (
    -- For each team-game: what did this team look like BEFORE kickoff?
    SELECT
        game_id,
        team,
        pregame_elo,
        count(*) OVER s                                        AS games_prior,

        -- season-to-date (prior games this season only)
        round(avg(win::int)  OVER s, 3)                        AS win_pct_szn,
        round(avg(points_for) OVER s, 2)                       AS ppg_szn,
        round(avg(points_against) OVER s, 2)                   AS opp_ppg_szn,
        round(avg(margin) OVER s, 2)                           AS margin_szn,
        round(avg(total_yards) OVER s, 1)                      AS yards_pg_szn,
        round(avg(opp_total_yards) OVER s, 1)                  AS opp_yards_pg_szn,
        round(avg(pass_yards) OVER s, 1)                       AS pass_yards_pg_szn,
        round(avg(rush_yards) OVER s, 1)                       AS rush_yards_pg_szn,
        round(avg(turnovers) OVER s, 2)                        AS turnovers_pg_szn,
        round(avg(takeaways) OVER s, 2)                        AS takeaways_pg_szn,
        round(avg(possession_sec) OVER s / 60.0, 1)            AS possession_min_szn,
        round(avg(off_ppa) OVER s, 3)                          AS off_ppa_szn,
        round(avg(def_ppa) OVER s, 3)                          AS def_ppa_szn,

        -- recent form (last 5 prior games this season)
        round(avg(win::int) OVER l5, 3)                        AS win_pct_l5,
        round(avg(margin) OVER l5, 2)                          AS margin_l5,
        round(avg(points_for) OVER l5, 2)                      AS ppg_l5,
        round(avg(points_against) OVER l5, 2)                  AS opp_ppg_l5,

        -- days since this team's previous game (NULL for season opener)
        game_date - lag(game_date) OVER (
            PARTITION BY team, season ORDER BY game_date, game_id
        )                                                      AS rest_days
    FROM core.team_games
    WINDOW
        s  AS (PARTITION BY team, season ORDER BY game_date, game_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
        l5 AS (PARTITION BY team, season ORDER BY game_date, game_id
               ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING)
),
prev AS (
    -- prior-season summary per team
    SELECT season, team,
        round(wins::numeric / NULLIF(games, 0), 3)             AS win_pct,
        ppg,
        opp_ppg,
        ppg - opp_ppg                                          AS avg_margin
    FROM marts.team_season_stats
)
SELECT
    g.game_id, g.season, g.week, g.season_type, g.game_date,
    g.home_team, g.away_team, g.home_conf, g.away_conf,
    g.home_class, g.away_class, g.is_neutral, g.is_conf_game,

    -- ---------- HOME team, pre-game ----------
    h.pregame_elo      AS h_pregame_elo,
    h.games_prior      AS h_games_prior,
    h.win_pct_szn      AS h_win_pct_szn,   h.ppg_szn          AS h_ppg_szn,
    h.opp_ppg_szn      AS h_opp_ppg_szn,   h.margin_szn       AS h_margin_szn,
    h.yards_pg_szn     AS h_yards_pg_szn,  h.opp_yards_pg_szn AS h_opp_yards_pg_szn,
    h.pass_yards_pg_szn AS h_pass_yards_pg_szn, h.rush_yards_pg_szn AS h_rush_yards_pg_szn,
    h.turnovers_pg_szn AS h_turnovers_pg_szn, h.takeaways_pg_szn AS h_takeaways_pg_szn,
    h.possession_min_szn AS h_possession_min_szn,
    h.off_ppa_szn AS h_off_ppa_szn, h.def_ppa_szn AS h_def_ppa_szn,
    h.win_pct_l5 AS h_win_pct_l5, h.margin_l5 AS h_margin_l5,
    h.ppg_l5 AS h_ppg_l5, h.opp_ppg_l5 AS h_opp_ppg_l5,
    h.rest_days AS h_rest_days,
    ph.win_pct AS h_prev_win_pct, ph.ppg AS h_prev_ppg,
    ph.opp_ppg AS h_prev_opp_ppg, ph.avg_margin AS h_prev_margin,

    -- ---------- AWAY team, pre-game ----------
    a.pregame_elo      AS a_pregame_elo,
    a.games_prior      AS a_games_prior,
    a.win_pct_szn      AS a_win_pct_szn,   a.ppg_szn          AS a_ppg_szn,
    a.opp_ppg_szn      AS a_opp_ppg_szn,   a.margin_szn       AS a_margin_szn,
    a.yards_pg_szn     AS a_yards_pg_szn,  a.opp_yards_pg_szn AS a_opp_yards_pg_szn,
    a.pass_yards_pg_szn AS a_pass_yards_pg_szn, a.rush_yards_pg_szn AS a_rush_yards_pg_szn,
    a.turnovers_pg_szn AS a_turnovers_pg_szn, a.takeaways_pg_szn AS a_takeaways_pg_szn,
    a.possession_min_szn AS a_possession_min_szn,
    a.off_ppa_szn AS a_off_ppa_szn, a.def_ppa_szn AS a_def_ppa_szn,
    a.win_pct_l5 AS a_win_pct_l5, a.margin_l5 AS a_margin_l5,
    a.ppg_l5 AS a_ppg_l5, a.opp_ppg_l5 AS a_opp_ppg_l5,
    a.rest_days AS a_rest_days,
    pa.win_pct AS a_prev_win_pct, pa.ppg AS a_prev_ppg,
    pa.opp_ppg AS a_prev_opp_ppg, pa.avg_margin AS a_prev_margin,

    -- ---------- Home-minus-away differences ----------
    h.pregame_elo - a.pregame_elo  AS elo_diff,
    h.margin_szn  - a.margin_szn   AS margin_szn_diff,
    h.win_pct_szn - a.win_pct_szn  AS win_pct_szn_diff,
    h.margin_l5   - a.margin_l5    AS margin_l5_diff,
    ph.avg_margin - pa.avg_margin  AS prev_margin_diff,

    -- ---------- Betting market (closing line, home side; -7 = home favored by 7) ----------
    sp.spread                          AS home_spread,
    sp.over_under,

    -- ---------- TARGETS (never use as features) ----------
    g.score_home                       AS home_score,
    g.score_away                       AS away_score,
    g.score_home - g.score_away        AS home_margin,
    (g.score_home > g.score_away)      AS home_win
FROM core.games g
JOIN pre h ON h.game_id = g.game_id AND h.team = g.home_team
JOIN pre a ON a.game_id = g.game_id AND a.team = g.away_team
LEFT JOIN prev ph ON ph.team = g.home_team AND ph.season = g.season - 1
LEFT JOIN prev pa ON pa.team = g.away_team AND pa.season = g.season - 1
LEFT JOIN core.game_spreads sp ON sp.game_id = g.game_id;

ALTER TABLE marts.game_features ADD PRIMARY KEY (game_id);
CREATE INDEX ix_gf_season ON marts.game_features (season, week);
