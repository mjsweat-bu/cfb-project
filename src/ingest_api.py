import os, sys, time
from datetime import datetime

import requests
import psycopg2
from psycopg2.extras import execute_values, Json
from dotenv import load_dotenv

load_dotenv(".env")
load_dotenv(".api.env")

API_BASE = os.environ["API_BASE_URL"].rstrip("/")
API_KEY = os.environ["API_KEY"]

# Season-level endpoints -> function that builds a unique key for each record
TEAM_SEASON_ENDPOINTS = {
    "stats/season":          lambda r: f"{r['team']}|{r['statName']}",
    "stats/season/advanced": lambda r: r["team"],
    "records":               lambda r: str(r["teamId"]),
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


def get_conn():
    return psycopg2.connect(
        host="localhost", port=5432,
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    )


def fetch(endpoint, params):
    """GET with retries for rate limits (429) and server errors (5xx)."""
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


def load_games(conn, season):
    records = []
    for season_type in ("regular", "postseason"):
        records += fetch("games", {"year": season, "seasonType": season_type})
        time.sleep(1)
    rows = [(str(rec["id"]), season, Json(rec)) for rec in records]

    with conn.cursor() as cur:
        if rows:
            execute_values(cur, """
                INSERT INTO raw.api_games (source_id, season, payload)
                VALUES %s
                ON CONFLICT (source_id) DO UPDATE
                SET payload = EXCLUDED.payload, fetched_at = now()
            """, rows)
        log(cur, "games", season, len(rows))
    conn.commit()


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


def load_player_seasons(conn, season):
    load_season_endpoints(conn, season, "raw.api_player_seasons", PLAYER_SEASON_ENDPOINTS)


LOADERS = {
    "games": load_games,
    "team_seasons": load_team_seasons,
    "player_seasons": load_player_seasons,
}


if __name__ == "__main__":
    # python src\ingest_api.py                         -> games, current year (daily job)
    # python src\ingest_api.py 2004 2025               -> games, backfill a range
    # python src\ingest_api.py team_seasons 2004 2025  -> season stats + records
    # python src\ingest_api.py player_seasons 2004 2025 -> player stats, usage, PPA, roster
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
