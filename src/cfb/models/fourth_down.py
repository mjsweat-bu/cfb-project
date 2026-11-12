"""Fourth-down decision tool: go for it, kick a field goal, or punt?

    python -m cfb.models.fourth_down --season 2025                -> score every 4th down in 2025
    python -m cfb.models.fourth_down --season 2026 --week 5       -> one regular-season week
    python -m cfb.models.fourth_down --season 2025 --postseason   -> bowls and playoffs
    python -m cfb.models.fourth_down --season 2025 --no-save      -> print the summary only

Explored in notebooks/fourth_down_predictor/ (one notebook per model, plus
fourth_down_decision.ipynb, which uses this module). Each option is valued in
expected points (EP), from the offense's point of view:

    GO    = P(convert) x EP(us, 1st & 10 at ytg - distance)  +  (1 - P(convert)) x -EP(them, 1st & 10 at 100 - ytg)
    FG    = P(make) x 3                                       +  (1 - P(make))    x -EP(them, 1st & 10 at min(100 - ytg, 80))
    PUNT  = -EP(them, 1st & 10 at predicted opp_start_ytg)

and the highest is recommended. Uses the four models each notebook saves to
models/ (git-ignored; rerun a notebook's last cell to recreate its file):
ep_model.joblib, fg_model.joblib, punt_model.joblib, go_model.keras + go_prep.joblib.
Plays come from sql/analysis/fourth_down_decisions.sql. Results are written to
marts.fourth_down_decisions, one row per play; scoring the same plays again
replaces their rows.
"""
import argparse, os, time, warnings
from datetime import datetime

import joblib
import numpy as np
import pandas as pd
from sqlalchemy import text

from cfb import config
from cfb.db import engine, read_query

OPTIONS = ["go", "fg", "punt"]                                 # column order of every value array below
COACH_DECISIONS = {"go": "go", "field goal": "fg", "punt": "punt"}   # labels in the data -> OPTIONS
MAX_KICK = 65                                                  # longer field goals are not an option
MODEL_FILES = ["ep_model.joblib", "fg_model.joblib", "punt_model.joblib", "go_model.keras", "go_prep.joblib"]

# Spots with an obvious answer, as (yards_to_goal, distance, expected). Checked by
# tests/test_fourth_down.py and shown in the notebook; a retrained model that gets
# one of these wrong needs a closer look before its results are trusted.
SANITY_SPOTS = {
    "4th & 1 at midfield":  (50, 1, "go"),
    "4th & 10 at own 25":   (75, 10, "punt"),
    "4th & 20 at own 10":   (90, 20, "punt"),
    "4th & 15 at opp 20":   (20, 15, "fg"),
    "4th & goal at the 1":  (1, 1, "go"),
}


# ---------- loading ----------

def load_models(models_dir=config.MODELS_DIR):
    """The four saved models, as one dict: {'ep', 'go', 'fg', 'punt'}."""
    missing = [f for f in MODEL_FILES if not (models_dir / f).exists()]
    if missing:
        raise FileNotFoundError(f"missing in {models_dir}: {missing}. Run the save cell at the end of "
                                "each notebook in notebooks/fourth_down_predictor/.")
    os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")         # hide TensorFlow's startup messages
    import tensorflow as tf                                    # slow import: only when scoring

    models = {name: joblib.load(models_dir / f"{name}_model.joblib") for name in ["ep", "fg", "punt"]}
    models["go"] = joblib.load(models_dir / "go_prep.joblib")
    models["go"]["model"] = tf.keras.models.load_model(models_dir / "go_model.keras")
    ep = models["ep"]
    ep["class_points"] = np.array([ep["points"][c] for c in ep["model"].classes_])
    return models


def load_plays(season, week=None, postseason=False):
    """Every regulation 4th down in a season, or one regular-season week, or the postseason."""
    plays = read_query("fourth_down_decisions.sql", season=season)
    if postseason:
        plays = plays[plays["season_type"] == "postseason"]
    elif week is not None:                                     # postseason weeks restart at 1
        plays = plays[(plays["season_type"] == "regular") & (plays["week"] == week)]
    plays = plays[~plays["is_overtime"].fillna(False).astype(bool)].reset_index(drop=True)   # no overtime models

    # the training notebooks fed true/false columns to the models as 1.0 / 0.0
    bool_cols = plays.select_dtypes("bool").columns
    plays[bool_cols] = plays[bool_cols].astype(float)
    return plays


def scenario(base, yards_to_goal, distance):
    """A copy of one play (a 1-row DataFrame) moved to a new spot: for what-if checks."""
    row = base.copy()
    row["yards_to_goal"] = yards_to_goal
    row["distance"] = distance
    row["kick_distance"] = row["kick_distance_fixed"] = yards_to_goal + 17
    row["is_goal_to_go"] = float(distance >= yards_to_goal)
    return row


# ---------- valuing outcomes ----------

def ep_value(models, plays, yards_to_goal, score_margin):
    """EP for whoever has the ball, 1st & 10 at yards_to_goal, in each play's game situation."""
    ep = models["ep"]
    ytg = np.clip(np.asarray(yards_to_goal, dtype=float), 1, 99)
    states = pd.DataFrame({
        "season":           plays["season"].to_numpy(),
        "half":             np.where(plays["period"] <= 2, 1, 2),
        "sec_left_in_half": plays["sec_left_in_half"].to_numpy(),
        "down":             1,
        "distance":         np.minimum(10, ytg),               # 1st & 10, or 1st & goal inside the 10
        "yards_to_goal":    ytg,
        "is_goal_to_go":    (ytg <= 10).astype(float),
        "score_margin":     np.asarray(score_margin, dtype=float),
    })[ep["features"]]                                         # the column order the model was trained on
    return ep["model"].predict_proba(states) @ ep["class_points"]


def go_value(models, plays):
    """EP of going for it, and P(convert)."""
    go = models["go"]
    X = go["preprocessor"].transform(plays[go["features"]]).astype("float32")
    p = go["model"].predict(X, verbose=0).ravel()

    new_ytg = plays["yards_to_goal"] - plays["distance"]
    success = np.where(new_ytg <= 0, 7,                        # converting on goal-to-go is a touchdown
                       ep_value(models, plays, new_ytg, plays["score_margin"]))
    fail = -ep_value(models, plays, 100 - plays["yards_to_goal"], -plays["score_margin"])   # turnover on downs
    return p * success + (1 - p) * fail, p


def fg_value(models, plays):
    """EP of kicking, and P(make). Computed at any distance; score() rules out kicks over MAX_KICK."""
    fg = models["fg"]
    rate = fg["league_rate"]                                   # shrunk kicking rate, as in the notebook
    attempts = plays["fg_att_szn"].fillna(0)
    makes = (plays["fg_pct_szn"] * plays["fg_att_szn"]).fillna(0)
    X = plays.assign(
        fg_shrunk_rate=(makes + 10 * rate) / (attempts + 10),
        opp_start_ytg=np.nan,                                  # punt-only columns: empty on every kick
        net_punt_yards=np.nan,
    )[fg["features"]]
    with warnings.catch_warnings():                            # net_punt_yards was empty in training too
        warnings.filterwarnings("ignore", message="Skipping features without any observed values")
        q = fg["model"].predict_proba(X)[:, 1]

    miss_ytg = np.minimum(100 - plays["yards_to_goal"], 80)    # previous spot, or the 20 from inside the 20
    return q * 3 + (1 - q) * -ep_value(models, plays, miss_ytg, -plays["score_margin"]), q


def punt_value(models, plays):
    """EP of punting, and the predicted opponent start (yards to goal)."""
    punt = models["punt"]
    opp_start = punt["model"].predict(plays[punt["features"]]).clip(1, 99)
    return -ep_value(models, plays, opp_start, -plays["score_margin"]), opp_start


# ---------- deciding ----------

def decide(ev):
    """Best option per row from an (n, 3) array of go / fg / punt values (NaN = not an option).
    margin is the gap to the second-best option: how clear the call is, in points."""
    available = np.where(np.isnan(ev), -np.inf, ev)
    ranked = np.sort(available, axis=1)
    return pd.DataFrame({
        "recommend": np.array(OPTIONS)[available.argmax(axis=1)],
        "best_ev": ranked[:, -1],
        "margin": ranked[:, -1] - ranked[:, -2],
    })


def score(plays, models):
    """One row per play: the three values, the recommendation, and how the coach's call compares."""
    ev_go, p_convert = go_value(models, plays)
    ev_fg, p_make = fg_value(models, plays)
    ev_punt, opp_start = punt_value(models, plays)

    in_range = (plays["kick_distance_fixed"] <= MAX_KICK).to_numpy()
    raw = np.column_stack([ev_go, ev_fg, ev_punt])
    options = raw.copy()
    options[~in_range, 1] = np.nan                             # a 70-yard field goal isn't an option
    best = decide(options)

    coach = plays["decision"].map(COACH_DECISIONS)
    chosen = coach.map({o: i for i, o in enumerate(OPTIONS)}).to_numpy()
    ev_coach = raw[np.arange(len(raw)), chosen]                # raw: valued even if the coach kicked from 70

    out = plays[["play_id", "game_id", "season", "week", "season_type", "game_date", "offense", "defense",
                 "period", "sec_left_in_half", "score_margin", "distance", "yards_to_goal"]].copy()
    out["coach_decision"] = coach.to_numpy()
    out["recommend"] = best["recommend"].to_numpy()
    out["p_convert"], out["p_make"], out["pred_opp_start"] = p_convert, p_make, opp_start
    out["ev_go"], out["ev_fg"], out["ev_punt"] = options[:, 0], options[:, 1], options[:, 2]
    out["ev_coach"] = ev_coach
    out["margin"] = best["margin"].to_numpy()
    out["ep_lost"] = np.clip(best["best_ev"].to_numpy() - ev_coach, 0, None)   # 0 when the coach agreed
    return out


# ---------- saving ----------

TABLE_DDL = """
CREATE TABLE IF NOT EXISTS marts.fourth_down_decisions (
    play_id          text PRIMARY KEY,
    game_id          bigint,
    season           integer,
    week             integer,
    season_type      text,
    game_date        date,
    offense          text,
    defense          text,
    period           integer,
    sec_left_in_half integer,
    score_margin     integer,
    distance         integer,
    yards_to_goal    integer,
    coach_decision   text,                -- go / fg / punt
    recommend        text,                -- go / fg / punt
    p_convert        double precision,    -- go model
    p_make           double precision,    -- field goal model
    pred_opp_start   double precision,    -- punt model: opponent's yards to goal
    ev_go            double precision,    -- expected points of each option
    ev_fg            double precision,    -- NULL: kick longer than MAX_KICK
    ev_punt          double precision,
    ev_coach         double precision,    -- expected points of what the coach chose
    margin           double precision,    -- best option minus second best
    ep_lost          double precision,    -- best option minus the coach's choice
    scored_at        timestamp
)
"""


def save(results):
    """Write to marts.fourth_down_decisions, replacing any earlier rows for the same plays."""
    rows = results.assign(scored_at=datetime.now().replace(microsecond=0))
    rows["sec_left_in_half"] = rows["sec_left_in_half"].astype("Int64")   # NULL for a bad clock
    with engine.begin() as con:                                # one transaction: all or nothing
        con.execute(text("CREATE SCHEMA IF NOT EXISTS marts"))
        con.execute(text(TABLE_DDL))
        con.execute(text("DELETE FROM marts.fourth_down_decisions WHERE play_id = ANY(:ids)"),
                    {"ids": rows["play_id"].tolist()})
        rows.to_sql("fourth_down_decisions", con, schema="marts", if_exists="append",
                    index=False, method="multi", chunksize=1000)
    return len(rows)


def summary(results):
    agree = (results["coach_decision"] == results["recommend"]).mean()
    print(f"{len(results):,} fourth downs: coaches agreed with the model on {agree:.1%}, "
          f"{results['ep_lost'].mean():.3f} expected points lost per fourth down")
    print(pd.crosstab(results["coach_decision"], results["recommend"],
                      rownames=["coach"], colnames=["model"], margins=True))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Score 4th-down decisions with the four fourth-down models.")
    p.add_argument("--season", type=int, required=True)
    g = p.add_mutually_exclusive_group()
    g.add_argument("--week", type=int, help="one regular-season week (default: the whole season)")
    g.add_argument("--postseason", action="store_true", help="bowls and playoffs only")
    p.add_argument("--no-save", action="store_true", help="print the summary without writing the table")
    a = p.parse_args()

    t = time.time()
    plays = load_plays(a.season, a.week, a.postseason)
    if plays.empty:
        raise SystemExit("no fourth downs found for that season / week")
    print(f"loaded {len(plays):,} fourth downs ({time.time() - t:.0f}s)")

    results = score(plays, load_models())
    summary(results)
    if not a.no_save:
        n = save(results)
        print(f"saved {n:,} rows to marts.fourth_down_decisions ({time.time() - t:.0f}s total)")
