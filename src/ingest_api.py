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
SEASON_ENDPOINTS = {
    "stats/season":          lambda r: f"{r['team']}|{r['statName']}",
    "stats/season/advanced": lambda r: r["team"],
    "records":               lambda r: str(r["teamId"]),
}


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


def load_team_seasons(conn, season):
    for endpoint, key in SEASON_ENDPOINTS.items():
        records = fetch(endpoint, {"year": season})
        rows = [(endpoint, season, key(rec), Json(rec)) for rec in records]

        with conn.cursor() as cur:
            if rows:
                execute_values(cur, """
                    INSERT INTO raw.api_team_seasons (endpoint, season, record_key, payload)
                    VALUES %s
                    ON CONFLICT (endpoint, season, record_key) DO UPDATE
                    SET payload = EXCLUDED.payload, fetched_at = now()
                """, rows)
            log(cur, endpoint, season, len(rows))
        conn.commit()
        time.sleep(1)


LOADERS = {"games": load_games, "team_seasons": load_team_seasons}


if __name__ == "__main__":
    # python src\ingest_api.py                         -> games, current year (daily job)
    # python src\ingest_api.py 2004 2025               -> games, backfill a range
    # python src\ingest_api.py team_seasons 2004 2025  -> season stats + records
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
