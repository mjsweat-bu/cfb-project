"""Train the drive-scoring model: P(this drive scores), snap by snap.

    python -m cfb.models.drive_scoring                     -> train on 2014-2023, select/calibrate on 2024
    python -m cfb.models.drive_scoring --train-end 2024 --valid 2025

Same recipe as notebooks/scoring_pred_model.ipynb (where it was explored):
  * data: marts.play_features (built by sql/build/14_play_features.sql)
  * gradient boosting with "closer to the goal never lowers the probability";
    no sklearn early stopping (its random holdout leaks snaps from the same
    drive), the iteration count is picked on half of the validation season's games
  * Platt calibration fit on that same half; metrics reported on the other half
Saves models/drive_scoring_<timestamp>.joblib plus a .json with the metadata
(seasons, iterations, metrics, features). The test season is never touched here.
"""
import argparse, json
from datetime import datetime

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import brier_score_loss, log_loss, roc_auc_score

from cfb import config
from cfb.db import engine

TARGET = "drive_scored"
NUMERIC = [
    "distance", "yards_to_goal", "sec_left_in_half", "score_margin",
    "drive_play_num", "drive_yards_so_far", "drive_ppa_so_far", "drive_start_ytg",
    "off_ppa_szn", "off_success_szn", "off_ppd_szn", "def_ppa_szn", "def_ppd_szn",
    "off_elo", "def_elo", "offense_spread", "off_games_prior", "def_games_prior",
]
ORDINAL = ["down", "period"]
BINARY = ["is_overtime", "is_home", "is_neutral", "is_goal_to_go", "prev_play_success"]
FEATURES = NUMERIC + ORDINAL + BINARY

GB_PARAMS = dict(
    learning_rate=0.05,
    max_leaf_nodes=31,
    early_stopping=False,
    monotonic_cst={"yards_to_goal": -1},
    random_state=42,
)


def load(first_season, last_season):
    cols = ", ".join(["season", "game_id"] + FEATURES + [TARGET])
    df = pd.read_sql(
        f"SELECT {cols} FROM marts.play_features WHERE season BETWEEN {int(first_season)} AND {int(last_season)}",
        engine,
    )
    for c in BINARY:
        df[c] = df[c].astype("float")   # True/False/None -> 1.0/0.0/NaN
    return df


def to_logit(p):
    p = np.clip(p, 1e-6, 1 - 1e-6)
    return np.log(p / (1 - p)).reshape(-1, 1)


def metrics(y, p):
    return {"log_loss": round(log_loss(y, p), 4), "brier": round(brier_score_loss(y, p), 4),
            "auc": round(roc_auc_score(y, p), 4), "mean_pred": round(float(p.mean()), 4),
            "actual_rate": round(float(y.mean()), 4)}


def train(train_start, train_end, valid_season, max_iter=600, seed=42):
    df = load(train_start, valid_season)
    train = df[df["season"].between(train_start, train_end)]
    valid = df[df["season"] == valid_season]
    X_train, y_train = train[FEATURES], train[TARGET]
    X_valid, y_valid = valid[FEATURES], valid[TARGET]

    # split the validation season by game: one half selects + calibrates, the other evaluates
    rng = np.random.default_rng(seed)
    games = valid["game_id"].unique()
    is_select = valid["game_id"].isin(rng.choice(games, size=len(games) // 2, replace=False)).to_numpy()
    is_eval = ~is_select

    # pick the iteration count where select-half log loss bottoms out
    long = HistGradientBoostingClassifier(max_iter=max_iter, **GB_PARAMS).fit(X_train, y_train)
    curve = [(i, log_loss(y_valid[is_select], p[is_select, 1]))
             for i, p in enumerate(long.staged_predict_proba(X_valid), start=1) if i % 25 == 0]
    best_iter = min(curve, key=lambda t: t[1])[0]
    print(f"best iteration: {best_iter}")

    gb = HistGradientBoostingClassifier(max_iter=best_iter, **GB_PARAMS).fit(X_train, y_train)
    raw = gb.predict_proba(X_valid)[:, 1]
    platt = LogisticRegression().fit(to_logit(raw[is_select]), y_valid[is_select])
    final = platt.predict_proba(to_logit(raw))[:, 1]

    naive = np.full(is_eval.sum(), y_train.mean())
    results = {
        "naive": metrics(y_valid[is_eval], naive),
        "gradient_boosting": metrics(y_valid[is_eval], raw[is_eval]),
        "final_calibrated": metrics(y_valid[is_eval], final[is_eval]),
    }
    meta = {
        "model": "drive_scoring",
        "trained_at": datetime.now().isoformat(timespec="seconds"),
        "train_seasons": [train_start, train_end],
        "valid_season": valid_season,
        "best_iter": best_iter,
        "gb_params": {k: v for k, v in GB_PARAMS.items()},
        "feature_columns": FEATURES,
        "rows": {"train": int(len(train)), "valid_select": int(is_select.sum()), "valid_eval": int(is_eval.sum())},
        "metrics_valid_eval_half": results,
    }
    return {"gb": gb, "platt": platt, "feature_columns": FEATURES}, meta


def save(model, meta):
    config.MODELS_DIR.mkdir(exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d_%H%M")
    path = config.MODELS_DIR / f"drive_scoring_{stamp}.joblib"
    joblib.dump(model, path)
    path.with_suffix(".json").write_text(json.dumps(meta, indent=2))
    return path


def predict(model, X):
    """P(drive scores) for rows with model['feature_columns']."""
    raw = model["gb"].predict_proba(X[model["feature_columns"]])[:, 1]
    return model["platt"].predict_proba(to_logit(raw))[:, 1]


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Train the drive-scoring model.")
    p.add_argument("--train-start", type=int, default=2014)
    p.add_argument("--train-end", type=int, default=2023)
    p.add_argument("--valid", type=int, default=2024, help="season used to select iterations and calibrate")
    a = p.parse_args()

    model, meta = train(a.train_start, a.train_end, a.valid)
    path = save(model, meta)
    print(json.dumps(meta["metrics_valid_eval_half"], indent=2))
    print(f"saved {path} (+ .json)")
