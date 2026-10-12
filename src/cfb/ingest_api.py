"""Load CollegeFootballData API data into the raw.* tables (one mode per endpoint group).

    python -m cfb.ingest_api                          -> games, current season (daily job)
    python -m cfb.ingest_api 2004 2025                -> games, backfill a range
    python -m cfb.ingest_api team_seasons 2004 2025   -> season stats + records
    python -m cfb.ingest_api player_seasons 2004 2025 -> player stats, usage, PPA, roster
    python -m cfb.ingest_api plays 2016 2025          -> play-by-play (~18 calls per season)
    python -m cfb.ingest_api game_players 2004 2015   -> player box scores per game (~18 calls per season)
    python -m cfb.ingest_api game_teams 2004 2026     -> team box scores per game (~18 calls per season)
    python -m cfb.ingest_api lines 2004 2026          -> betting lines, all providers (2 calls per season)
    python -m cfb.ingest_api coaches_rankings 2000 2026 -> head coaches + weekly polls (2 calls per season)
"""
import sys, time
from datetime import datetime, timedelta, timezone

import requests
from psycopg2.extras import execute_values, Json

from cfb import config
from cfb.db import get_conn

API_BASE = config.API_BASE_URL
API_KEY = config.API_KEY

# Season-level endpoints -> function that builds a unique key for each record
TEAM_SEASON_ENDPOINTS = {
    "stats/season":          lambda r: f"{r['team']}|{r['statName']}",
    "stats/season/advanced": lambda r: r["team"],
    "records":               lambda r: str(r["teamId"]),
}

# Head coaches and weekly polls, stored in raw.api_team_seasons next to the season stats.
COACH_RANKING_ENDPOINTS = {
    "coaches":  lambda r: str(r.get("id") or f"{r['firstName']}|{r['lastName']}|{r.get('hireDate') or ''}"),
    "rankings": lambda r: f"{r['seasonType']}|{r['week']}",
}

# Bulk equivalents of /player/season/overview (which needs one call per player):
# box score stats + usage + PPA, plus roster for bio info.
PLAYER_SEASON_ENDPOINTS = {
    "stats/player/season": lambda r: f"{r['playerId']}|{r['team']}",
    "player/usage":        lambda r: f"{r['id']}|{r['team']}",
    "ppa/players/season":  lambda r: f"{r['id']}|{r['team']}",
    "roster":              lambda r: f"{r['id']}|{r['team']}",
}


def group_player_stats(records):
    """stats/player/season returns one row per player per stat (~135k/season).
    Group into one record per player: stats = {category: {statType: value}}."""
    players = {}
    for r in records:
        p = players.setdefault((r["playerId"], r["team"]), {
            k: r[k] for k in ("season", "playerId", "player", "position", "team", "conference")
        } | {"stats": {}})
        p["stats"].setdefault(r["category"], {})[r["statType"]] = r["stat"]
    return list(players.values())


PREPARE = {"stats/player/season": group_player_stats}


def fetch(endpoint, params):
    """GET with retries for rate limits (429) and server errors (5xx)."""
    if not API_KEY:
        raise RuntimeError("API_KEY is not set: add it to .api.env at the project root")
    for attempt in range(4):
        r = requests.get(
            f"{API_BASE}/{endpoint}",
            params=params,
            headers={"Authorization": f"Bearer {API_KEY}"},
            timeout=60,
        )
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(5 * 2 ** attempt)
            continue
        r.raise_for_status()
        return r.json()
    raise RuntimeError(f"API kept failing for {endpoint} {params}")


def log(cur, endpoint, season, n):
    cur.execute(
        "INSERT INTO raw.ingest_log (endpoint, season, rows, status) VALUES (%s,%s,%s,%s)",
        (endpoint, season, n, "ok"),
    )
    print(f"{datetime.now():%Y-%m-%d %H:%M} {endpoint} season {season}: {n} records")


def load_per_game(conn, season, endpoint, table):
    """Endpoints that return one record per game, keyed by the game ID."""
    records = []
    for season_type in ("regular", "postseason"):
        records += fetch(endpoint, {"year": season, "seasonType": season_type})
        time.sleep(1)
    rows = [(str(rec["id"]), season, Json(rec)) for rec in records]

    with conn.cursor() as cur:
        if rows:
            execute_values(cur, f"""
                INSERT INTO {table} (source_id, season, payload)
                VALUES %s
                ON CONFLICT (source_id) DO UPDATE
                SET payload = EXCLUDED.payload, fetched_at = now()
            """, rows)
        log(cur, endpoint, season, len(rows))
    conn.commit()


def load_games(conn, season):
    load_per_game(conn, season, "games", "raw.api_games")


def load_lines(conn, season):
    load_per_game(conn, season, "lines", "raw.api_lines")


def load_season_endpoints(conn, season, table, endpoints):
    for endpoint, key in endpoints.items():
        records = fetch(endpoint, {"year": season})
        if endpoint in PREPARE:
            records = PREPARE[endpoint](records)
        # keyed dict drops exact repeats (player/usage returns some records twice)
        by_key = {key(rec): rec for rec in records}
        rows = [(endpoint, season, k, Json(rec)) for k, rec in by_key.items()]

        with conn.cursor() as cur:
            if rows:
                execute_values(cur, f"""
                    INSERT INTO {table} (endpoint, season, record_key, payload)
                    VALUES %s
                    ON CONFLICT (endpoint, season, record_key) DO UPDATE
                    SET payload = EXCLUDED.payload, fetched_at = now()
                """, rows)
            log(cur, endpoint, season, len(rows))
        conn.commit()
        time.sleep(1)


def load_team_seasons(conn, season):
    load_season_endpoints(conn, season, "raw.api_team_seasons", TEAM_SEASON_ENDPOINTS)


def load_coaches_rankings(conn, season):
    load_season_endpoints(conn, season, "raw.api_team_seasons", COACH_RANKING_ENDPOINTS)


def load_player_seasons(conn, season):
    load_season_endpoints(conn, season, "raw.api_player_seasons", PLAYER_SEASON_ENDPOINTS)


# Weekly endpoints -> (raw table, record ID field, game ID field)
WEEKLY_ENDPOINTS = {
    "plays":         ("raw.api_plays",        "id", "gameId"),   # one row per play
    "games/players": ("raw.api_game_players", "id", "id"),       # one row per game
    "games/teams":   ("raw.api_game_teams",   "id", "id"),       # one row per game
}


def load_weekly(conn, season, endpoint):
    """FBS games' data, one call per calendar week (~18 per season).
    Weeks already loaded that ended over 7 days ago are skipped, so a daily
    run of the current season only refetches recent weeks."""
    table, id_field, game_field = WEEKLY_ENDPOINTS[endpoint]
    now = datetime.now(timezone.utc)
    with conn.cursor() as cur:
        cur.execute(f"SELECT DISTINCT season_type, week FROM {table} WHERE season = %s", (season,))
        loaded = set(cur.fetchall())

    calendar = fetch("calendar", {"year": season})
    if not calendar and season < now.year:
        # the API has no calendar for some early seasons (e.g. 2001) even though
        # it has their plays: fall back to regular weeks 1-16 plus the postseason
        long_ago = "2000-01-01T00:00:00Z"
        calendar = [{"seasonType": "regular", "week": w, "startDate": long_ago, "endDate": long_ago}
                    for w in range(1, 17)]
        calendar.append({"seasonType": "postseason", "week": 1, "startDate": long_ago, "endDate": long_ago})

    for wk in calendar:
        season_type, week = wk["seasonType"], wk["week"]
        start = datetime.fromisoformat(wk["startDate"].replace("Z", "+00:00"))
        end = datetime.fromisoformat(wk["endDate"].replace("Z", "+00:00"))
        if start > now:
            continue    # not played yet
        if (season_type, week) in loaded and end < now - timedelta(days=7):
            continue    # already loaded and settled

        records = fetch(endpoint, {"year": season, "week": week,
                                   "seasonType": season_type, "classification": "fbs"})
        by_id = {str(r[id_field]): r for r in records}
        rows = [(rid, season, season_type, week, r[game_field], Json(r)) for rid, r in by_id.items()]

        with conn.cursor() as cur:
            if rows:
                execute_values(cur, f"""
                    INSERT INTO {table} (source_id, season, season_type, week, game_id, payload)
                    VALUES %s
                    ON CONFLICT (source_id) DO UPDATE
                    SET payload = EXCLUDED.payload, fetched_at = now()
                """, rows, page_size=1000)
            log(cur, f"{endpoint} {season_type} wk {week}", season, len(rows))
        conn.commit()
        time.sleep(1)


def load_plays(conn, season):
    load_weekly(conn, season, "plays")


def load_game_players(conn, season):
    load_weekly(conn, season, "games/players")


def load_game_teams(conn, season):
    load_weekly(conn, season, "games/teams")


LOADERS = {
    "games": load_games,
    "team_seasons": load_team_seasons,
    "player_seasons": load_player_seasons,
    "plays": load_plays,
    "game_players": load_game_players,
    "game_teams": load_game_teams,
    "lines": load_lines,
    "coaches_rankings": load_coaches_rankings,
}


if __name__ == "__main__":
    # usage: see the module docstring
    args = sys.argv[1:]
    loader = LOADERS[args.pop(0)] if args and args[0] in LOADERS else load_games
    years = [int(a) for a in args]
    if len(years) == 2:
        seasons = range(years[0], years[1] + 1)
    elif len(years) == 1:
        seasons = [years[0]]
    else:
        seasons = [datetime.now().year]

    conn = get_conn()
    for s in seasons:
        loader(conn, s)
        time.sleep(1)   # be polite to the API
    conn.close()
