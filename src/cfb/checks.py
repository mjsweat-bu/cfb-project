"""Data checks run after every build (python -m cfb.refresh) and by pytest.

Each check is a query that returns one number: how many rows break the rule.
0 = pass. Add a check whenever a data problem is found, so it can't come back
unnoticed.
"""
from sqlalchemy import text

from cfb.db import engine

CHECKS = [
    ("games_loaded",
     "core.games has rows",
     "SELECT CASE WHEN count(*) > 0 THEN 0 ELSE 1 END FROM core.games"),

    ("two_team_rows_per_game",
     "every game has exactly two rows in core.team_games",
     """SELECT count(*) FROM core.games g
        WHERE (SELECT count(*) FROM core.team_games t WHERE t.game_id = g.game_id) <> 2"""),

    ("team_scores_match_games",
     "core.team_games points agree with core.games",
     """SELECT count(*) FROM core.team_games t JOIN core.games g USING (game_id)
        WHERE t.points_for <> CASE WHEN t.team = g.home_team THEN g.score_home ELSE g.score_away END"""),

    ("turnovers_add_up",
     "box-score turnovers = fumbles lost + interceptions thrown",
     """SELECT count(*) FROM core.team_games
        WHERE has_stats AND turnovers <> fumbles_lost + ints_thrown"""),

    ("box_score_coverage",
     "no season (2004+, where /games/teams is loaded) has box scores for under 90% of team-games",
     """SELECT count(*) FROM (
            SELECT season FROM core.team_games WHERE season >= 2004 GROUP BY season
            HAVING avg(has_stats::int) < 0.9) x"""),

    ("one_ap_rank_per_team_week",
     "core.poll_ranks has at most one AP rank per team per week",
     """SELECT count(*) FROM (
            SELECT 1 FROM core.poll_ranks WHERE poll = 'AP Top 25'
            GROUP BY season, season_type, week, team HAVING count(*) > 1) x"""),

    ("one_feature_row_per_game",
     "marts.game_features has one row per core.games row",
     "SELECT abs((SELECT count(*) FROM marts.game_features) - (SELECT count(*) FROM core.games))"),

    ("drive_results_valid",
     "every drive result is a known category",
     """SELECT count(*) FROM core.drives
        WHERE result NOT IN ('TD', 'FG', 'MISSED FG', 'PUNT', 'INT', 'FUMBLE', 'SAFETY',
                             'DOWNS', 'END OF HALF', 'END OF GAME', 'OTHER')"""),

    ("play_features_field_position",
     "marts.play_features yards_to_goal is between 1 and 99",
     "SELECT count(*) FROM marts.play_features WHERE yards_to_goal NOT BETWEEN 1 AND 99"),

    ("fourth_down_outcome_matches_decision",
     "marts.fourth_down_features outcomes belong to their decision",
     """SELECT count(*) FROM marts.fourth_down_features
        WHERE NOT (
              (decision = 'go'         AND outcome IN ('converted', 'failed', 'turnover'))
           OR (decision = 'field goal' AND outcome IN ('fg_made', 'fg_missed', 'fg_blocked'))
           OR (decision = 'punt'       AND outcome LIKE 'punt\\_%'))"""),
]


def run_checks(verbose=False):
    """Run every check; return the names of the ones that failed."""
    failures = []
    with engine.connect() as conn:
        for name, description, sql in CHECKS:
            bad = conn.execute(text(sql)).scalar()
            ok = bad == 0
            if not ok:
                failures.append(name)
            if verbose:
                print(f"--- check {'ok  ' if ok else 'FAIL'} {name}: {description}"
                      + ("" if ok else f" ({bad} bad)"))
    return failures
