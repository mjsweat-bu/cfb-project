"""Fourth-down decisions dashboard.

    streamlit run dashboard/app.py

Reads marts.fourth_down_decisions, which `python -m cfb.models.fourth_down --season <year>`
fills. The "What if" page runs the four models live (the first use of a season loads
its plays, about 20 seconds; cached after that). The database must be running.
"""
import altair as alt
import pandas as pd
import streamlit as st
from sqlalchemy import text

from cfb.db import engine
from cfb.models import fourth_down as fd

st.set_page_config(page_title="4th Down Decisions", page_icon="🏈", layout="wide")

LABELS = {"go": "Go for it", "fg": "Field goal", "punt": "Punt"}
TOSS_UP = 0.3            # margins under this many points are close calls


# ---------- helpers ----------

def spot(ytg):
    """Yards to goal as a yard line: 'own 25', 'opp 35', 'midfield'."""
    if ytg == 50:
        return "midfield"
    return f"own {100 - ytg}" if ytg > 50 else f"opp {ytg}"


def situation(distance, ytg):
    return f"4th & {'goal' if distance >= ytg else distance} at {spot(ytg)}"


def pct(s):
    return 100 * s


@st.cache_data(ttl=300)
def available_seasons():
    try:
        return pd.read_sql("SELECT DISTINCT season FROM marts.fourth_down_decisions ORDER BY season DESC",
                           engine)["season"].tolist()
    except Exception:
        return []


@st.cache_data(ttl=300)
def load_decisions(season):
    """Scored 4th downs for a season, with the offense's conference and division."""
    query = text("""
        WITH team_conf AS (
            SELECT DISTINCT ON (team) team, conf, division
            FROM (
                SELECT home_team AS team, home_conf AS conf, home_class AS division, game_date
                FROM core.games WHERE season = :season
                UNION ALL
                SELECT away_team, away_conf, away_class, game_date
                FROM core.games WHERE season = :season
            ) t
            ORDER BY team, game_date DESC
        )
        SELECT d.*, c.conf, c.division
        FROM marts.fourth_down_decisions d
        LEFT JOIN team_conf c ON c.team = d.offense
        WHERE d.season = :season
    """)
    df = pd.read_sql(query, engine, params={"season": int(season)})
    df["situation"] = [situation(d, y) for d, y in zip(df["distance"], df["yards_to_goal"])]
    df["agree"] = df["coach_decision"] == df["recommend"]
    df["coach"] = df["coach_decision"].map(LABELS)
    df["model"] = df["recommend"].map(LABELS)
    return df


@st.cache_resource(show_spinner="Loading the four models...")
def get_models():
    return fd.load_models()


@st.cache_data(show_spinner="Loading this season's 4th downs (about 20 seconds the first time)...")
def get_plays(season):
    return fd.load_plays(season)


def team_table(df, min_plays):
    """One row per offense, ranked by expected points lost per 4th down (1 = fewest)."""
    t = (df.groupby(["offense", "conf"], dropna=False)
           .agg(fourth_downs=("play_id", "size"),
                agree=("agree", "mean"),
                coach_go=("coach_decision", lambda s: (s == "go").mean()),
                model_go=("recommend", lambda s: (s == "go").mean()),
                ep_lost_per=("ep_lost", "mean"),
                ep_lost_total=("ep_lost", "sum"))
           .reset_index())
    t = t[t["fourth_downs"] >= min_plays].sort_values("ep_lost_per").reset_index(drop=True)
    t.insert(0, "rank", range(1, len(t) + 1))
    return t


def calls_table(df):
    """Plays as a readable table."""
    return df[["week", "offense", "defense", "period", "score_margin", "situation", "coach", "model",
               "p_convert", "p_make", "margin", "ep_lost"]].rename(columns={
        "week": "Week", "offense": "Offense", "defense": "Opponent", "period": "Qtr",
        "score_margin": "Score", "situation": "Situation", "coach": "Coach", "model": "Model",
        "p_convert": "P(convert)", "p_make": "P(make)", "margin": "Margin", "ep_lost": "EP lost"})


CALLS_CONFIG = {
    "Score": st.column_config.NumberColumn(help="Offense's lead (negative = trailing)", format="%+d"),
    "P(convert)": st.column_config.NumberColumn(format="%.2f"),
    "P(make)": st.column_config.NumberColumn(format="%.2f"),
    "Margin": st.column_config.NumberColumn(help="How far the model's choice beats its second choice, in points",
                                            format="%.2f"),
    "EP lost": st.column_config.NumberColumn(help="Model's best option minus the coach's choice, in points",
                                             format="%.2f"),
}


# ---------- sidebar ----------

seasons = available_seasons()
if not seasons:
    st.error("No scored 4th downs found. Is the database running? Score a season first with:\n\n"
             "`python -m cfb.models.fourth_down --season 2025`")
    st.stop()

st.sidebar.title("4th Down Decisions")
page = st.sidebar.radio("Page", ["League", "Team", "Week", "What if"])
season = st.sidebar.selectbox("Season", seasons)
fbs_only = st.sidebar.checkbox("FBS offenses only", value=True)
max_margin = st.sidebar.slider("Score within (points)", 0, 60, 16,
                               help="Expected points value points, not wins: a team down 30 should "
                                    "take risks the model calls mistakes. 16 = two scores.")
st.sidebar.caption("The go-for-it model runs a few points optimistic on 4th & 2 to 4th & 7, "
                   "so the model leans toward going for it there.")

decisions = load_decisions(season)
f = decisions[decisions["score_margin"].abs() <= max_margin]
if fbs_only:
    f = f[f["division"] == "fbs"]


# ---------- pages ----------

if page == "League":
    st.title(f"{season} 4th-down decisions")

    c = st.columns(4)
    c[0].metric("4th downs", f"{len(f):,}")
    c[1].metric("Coaches agreed with the model", f"{f['agree'].mean():.0%}")
    c[2].metric("Expected points lost per 4th down", f"{f['ep_lost'].mean():.3f}")
    c[3].metric("Go-for-it rate: coaches vs model",
                f"{(f['coach_decision'] == 'go').mean():.0%} vs {(f['recommend'] == 'go').mean():.0%}")

    confs = st.multiselect("Conferences (none selected = all)", sorted(f["conf"].dropna().unique()))
    min_plays = st.slider("Minimum 4th downs per team", 10, 100, 40)
    teams = team_table(f[f["conf"].isin(confs)] if confs else f, min_plays)

    st.subheader("Team rankings")
    st.caption("Rank 1 = fewest expected points lost per 4th down.")
    st.dataframe(
        teams.assign(agree=pct(teams["agree"]), coach_go=pct(teams["coach_go"]), model_go=pct(teams["model_go"])),
        hide_index=True, height=420,
        column_config={
            "rank": "Rank", "offense": "Team", "conf": "Conference", "fourth_downs": "4th downs",
            "agree": st.column_config.NumberColumn("Agreed with model", format="%.0f%%"),
            "coach_go": st.column_config.NumberColumn("Coach go rate", format="%.0f%%"),
            "model_go": st.column_config.NumberColumn("Model go rate", format="%.0f%%"),
            "ep_lost_per": st.column_config.NumberColumn("EP lost per 4th down", format="%.3f"),
            "ep_lost_total": st.column_config.NumberColumn("EP lost (total)", format="%.1f"),
        })

    st.subheader("Aggressiveness vs expected points lost")
    chart = (alt.Chart(teams).mark_circle(size=70).encode(
                x=alt.X("coach_go:Q", title="Coach go-for-it rate", axis=alt.Axis(format="%")),
                y=alt.Y("ep_lost_per:Q", title="Expected points lost per 4th down"),
                tooltip=[alt.Tooltip("offense:N", title="Team"),
                         alt.Tooltip("coach_go:Q", title="Coach go rate", format=".0%"),
                         alt.Tooltip("model_go:Q", title="Model go rate", format=".0%"),
                         alt.Tooltip("ep_lost_per:Q", title="EP lost per 4th", format=".3f")])
             .properties(height=420))
    st.altair_chart(chart, width="stretch")

elif page == "Team":
    names = sorted(f["offense"].unique())
    team = st.selectbox("Team", names, index=names.index("Auburn") if "Auburn" in names else 0)
    t = f[f["offense"] == team]
    st.title(f"{team}: {season} 4th downs")

    league = team_table(f, 1)
    rank = league.loc[league["offense"] == team, "rank"]
    c = st.columns(4)
    c[0].metric("4th downs", len(t))
    c[1].metric("Agreed with the model", f"{t['agree'].mean():.0%}")
    c[2].metric("EP lost per 4th down", f"{t['ep_lost'].mean():.3f}",
                help=f"Rank {int(rank.iloc[0])} of {len(league)} (1 = fewest lost)" if len(rank) else None)
    c[3].metric("Go-for-it rate: coach vs model",
                f"{(t['coach_decision'] == 'go').mean():.0%} vs {(t['recommend'] == 'go').mean():.0%}")

    left, right = st.columns(2)
    with left:
        st.subheader("Coach vs model")
        st.caption("Rows: what the coach did. Columns: what the model recommended.")
        st.dataframe(pd.crosstab(t["coach"], t["model"], margins=True, margins_name="Total"))
    with right:
        st.subheader("Expected points lost by week")
        by_week = t.groupby("week", as_index=False)["ep_lost"].sum()
        st.altair_chart(alt.Chart(by_week).mark_bar().encode(
            x=alt.X("week:O", title="Week"),
            y=alt.Y("ep_lost:Q", title="Expected points lost")).properties(height=280),
            width="stretch")

    st.subheader("Every 4th down, costliest first")
    st.dataframe(calls_table(t.sort_values("ep_lost", ascending=False)), hide_index=True,
                 column_config=CALLS_CONFIG)

elif page == "Week":
    regular = sorted(f.loc[f["season_type"] == "regular", "week"].unique())
    options = [f"Week {w}" for w in regular] + (["Postseason"] if (f["season_type"] == "postseason").any() else [])
    choice = st.selectbox("Week", options, index=len(regular) - 1 if regular else 0)
    w = (f[f["season_type"] == "postseason"] if choice == "Postseason"
         else f[(f["season_type"] == "regular") & (f["week"] == int(choice.split()[1]))])
    st.title(f"{season} {choice}: 4th-down decisions")

    c = st.columns(3)
    c[0].metric("4th downs", len(w))
    c[1].metric("Coaches agreed with the model", f"{w['agree'].mean():.0%}")
    c[2].metric("Expected points lost", f"{w['ep_lost'].sum():.1f}")

    st.subheader("Costliest calls")
    st.dataframe(calls_table(w.sort_values("ep_lost", ascending=False).head(10)), hide_index=True,
                 column_config=CALLS_CONFIG)

    st.subheader("Best go-for-it calls")
    st.caption("The coach went for it and the model agreed, clearest calls first.")
    best = w[(w["coach_decision"] == "go") & (w["recommend"] == "go")].sort_values("margin", ascending=False)
    st.dataframe(calls_table(best.head(10)), hide_index=True, column_config=CALLS_CONFIG)

else:   # What if
    st.title("What would the model do?")
    st.caption("Uses the team's strength, kicker and opponent from its most recent 4th down this season; "
               "you set the situation.")

    plays = get_plays(season)
    models = get_models()

    names = sorted(plays["offense"].unique())
    left, right = st.columns(2)
    with left:
        team = st.selectbox("Team", names, index=names.index("Auburn") if "Auburn" in names else 0)
        quarter = st.selectbox("Quarter", [1, 2, 3, 4], index=1)
        mins = st.number_input("Minutes left in the quarter", 0, 15, 8)
        secs = st.number_input("Seconds", 0, 59, 0)
    with right:
        side = st.radio("Ball on", ["Own side", "Opponent's side"], horizontal=True, index=1)
        yard_line = st.number_input("Yard line", 1, 50, 35)
        distance = st.number_input("Yards to go", 1, 99, 3)
        margin = st.slider("Score (your team's lead)", -35, 35, 0)

    ytg = 100 - yard_line if side == "Own side" else yard_line
    distance = min(distance, ytg)                                  # past the goal line = 4th & goal
    clock = min(mins * 60 + secs, 900)

    base = plays[plays["offense"] == team].iloc[[-1]]              # latest 4th down: current team strength
    row = fd.scenario(base, ytg, distance)
    row["score_margin"] = margin
    row["period"] = quarter
    row["sec_left_in_half"] = clock + (900 if quarter in (1, 3) else 0)
    row["sec_left_in_game"] = (4 - quarter) * 900 + clock
    r = fd.score(row, models).iloc[0]

    lead = "tied" if margin == 0 else (f"up {margin}" if margin > 0 else f"down {-margin}")
    st.subheader(f"{situation(distance, ytg)}, Q{quarter} {mins}:{secs:02d}, {lead}")

    c = st.columns(3)
    c[0].metric("Go for it", f"{r['ev_go']:+.2f} pts")
    c[0].caption(f"Converts {r['p_convert']:.0%} of the time")
    if pd.isna(r["ev_fg"]):
        c[1].metric("Field goal", "Out of range")
        c[1].caption(f"{ytg + 17}-yard attempt")
    else:
        c[1].metric("Field goal", f"{r['ev_fg']:+.2f} pts")
        c[1].caption(f"{ytg + 17}-yard attempt, good {r['p_make']:.0%} of the time")
    c[2].metric("Punt", f"{r['ev_punt']:+.2f} pts")
    c[2].caption(f"Opponent starts at about their own {100 - r['pred_opp_start']:.0f}")

    best = LABELS[r["recommend"]]
    if r["margin"] < TOSS_UP:
        st.info(f"Toss-up: {best} by only {r['margin']:.2f} expected points.")
    else:
        st.success(f"Recommendation: **{best}**, by {r['margin']:.2f} expected points over the next best option.")
    st.caption("Expected points = the average points this possession is worth, counting the next score in "
               "the half either way. It values points, not wins, so late in a lopsided game trust it less.")
