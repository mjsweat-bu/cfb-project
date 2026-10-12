"""Refresh the current season: load new API data, rebuild the tables, run the data checks.

    python -m cfb.refresh                 -> load + rebuild + check the current season (~19 API calls)
    python -m cfb.refresh --season 2025   -> a different season
    python -m cfb.refresh --skip-load     -> rebuild + check only (no API calls)
    python -m cfb.refresh --full-rebuild  -> also rebuild 07 (2004-2015 player box scores, ~70s)
    python -m cfb.refresh --checks-only   -> just run the data checks

Run from anywhere; the database container must be up (docker compose up -d).
Stops at the first failed load or build script, and exits with an error if a
data check fails. Each build script runs in a transaction, so a failure leaves
that table as it was.
"""
import argparse, subprocess, sys, time
from datetime import datetime

from cfb import config
from cfb import ingest_api as ia
from cfb.checks import run_checks

# Loads for one season, in order. game_players is left out: it only covers 2004-2015.
# plays and game_teams refetch only weeks not loaded yet or that ended in the last 7 days.
LOADS = ["games", "plays", "game_teams", "team_seasons", "player_seasons", "lines", "coaches_rankings"]

# Build scripts skipped unless --full-rebuild: their inputs don't change in-season.
STATIC_SCRIPTS = {"07"}   # core.player_games (2004-2015)


def psql(args):
    """Run psql inside the database container; return (exit code, output)."""
    cmd = ["docker", "exec", config.DB_CONTAINER, "sh", "-c",
           'psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" ' + args]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def load(season):
    conn = ia.get_conn()
    try:
        for mode in LOADS:
            print(f"--- load {mode} {season}")
            ia.LOADERS[mode](conn, season)
            time.sleep(1)   # be polite to the API
    finally:
        conn.close()


def build(full):
    # numeric order = build order (raw -> core -> marts)
    scripts = sorted(config.SQL_BUILD_DIR.glob("[0-9][0-9]_*.sql"))
    container_dir = f"{config.DB_CONTAINER_SQL_DIR}/{config.SQL_BUILD_DIR.name}"
    for path in scripts:
        if path.name[:2] in STATIC_SCRIPTS and not full:
            print(f"--- skip  {path.name} (static; use --full-rebuild)")
            continue
        start = time.time()
        code, out = psql(f"-1 -f {container_dir}/{path.name}")
        errors = [l for l in out.splitlines() if "ERROR" in l]
        if code != 0:
            print(f"--- FAIL  {path.name}")
            print("\n".join(errors) or out)
            sys.exit(1)
        print(f"--- built {path.name} ({time.time() - start:.0f}s)")


def check():
    failures = run_checks(verbose=True)
    if failures:
        print(f"--- {len(failures)} data check(s) FAILED: {', '.join(failures)}")
        sys.exit(1)


def summary(season):
    code, out = psql(f"""-A -c "
        SELECT season_type, max(week) AS last_week, count(*) AS games
        FROM core.games WHERE season = {season}
        GROUP BY season_type ORDER BY season_type DESC" """)
    print(f"--- {season} games in core.games:")
    print(out.strip())


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Refresh one season of API data and rebuild the tables.")
    p.add_argument("--season", type=int, default=datetime.now().year)
    p.add_argument("--skip-load", action="store_true", help="rebuild only, no API calls")
    p.add_argument("--full-rebuild", action="store_true", help="also rebuild static scripts (07)")
    p.add_argument("--checks-only", action="store_true", help="only run the data checks")
    a = p.parse_args()

    if not a.checks_only:
        if not a.skip_load:
            load(a.season)
        build(a.full_rebuild)
        summary(a.season)
    check()
