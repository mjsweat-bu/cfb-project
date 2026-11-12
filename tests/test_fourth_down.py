"""Tests for cfb.models.fourth_down.

decide() needs nothing. The sanity spots need the saved models in models/ and the
database; they are skipped when either is missing (models/ is git-ignored, so a
fresh clone skips them until the notebooks' save cells have been run).
"""
import numpy as np
import pytest

from cfb import config
from cfb.models import fourth_down as fd


# ---------- decide(): no models or database needed ----------

def test_decide_picks_highest():
    ev = np.array([[1.0, 0.5, -0.2],     # go
                   [-1.0, 2.0, 0.3],     # fg
                   [-2.0, -1.5, -0.4]])  # punt
    assert fd.decide(ev)["recommend"].tolist() == ["go", "fg", "punt"]


def test_decide_skips_options_that_are_not_available():
    ev = np.array([[0.1, np.nan, -0.3]])           # field goal out of range
    out = fd.decide(ev)
    assert out["recommend"].iloc[0] == "go"
    assert out["margin"].iloc[0] == pytest.approx(0.4)


def test_margin_is_gap_to_second_best():
    ev = np.array([[2.0, 1.5, -1.0]])
    assert fd.decide(ev)["margin"].iloc[0] == pytest.approx(0.5)


# ---------- the saved models on spots with an obvious answer ----------

@pytest.fixture(scope="module")
def models():
    if not all((config.MODELS_DIR / f).exists() for f in fd.MODEL_FILES):
        pytest.skip("fourth-down models not saved in models/")
    return fd.load_models()


@pytest.fixture(scope="module")
def base_play(models):
    """A real 1st-quarter, tied-score 4th down to build the what-if spots from."""
    try:
        plays = fd.load_plays(2025, week=5)
    except Exception as e:                                   # database not running
        pytest.skip(f"database not available: {e}")
    return plays[(plays["period"] == 1) & (plays["score_margin"] == 0)].iloc[[0]]


@pytest.mark.parametrize("spot", list(fd.SANITY_SPOTS))
def test_sanity_spot(models, base_play, spot):
    ytg, distance, expected = fd.SANITY_SPOTS[spot]
    result = fd.score(fd.scenario(base_play, ytg, distance), models).iloc[0]
    assert result["recommend"] == expected, (
        f"{spot}: expected {expected}, got {result['recommend']} "
        f"(go {result['ev_go']:.2f}, fg {result['ev_fg']:.2f}, punt {result['ev_punt']:.2f})"
    )


def test_out_of_range_field_goal_is_not_an_option(models, base_play):
    result = fd.score(fd.scenario(base_play, 60, 5), models).iloc[0]   # 77-yard kick
    assert np.isnan(result["ev_fg"])
    assert result["recommend"] != "fg"
