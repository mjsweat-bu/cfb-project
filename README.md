# College Football Data Pipeline

An end-to-end data science project: raw CSV + CollegeFootballData API -> PostgreSQL (Docker) -> SQL modeling -> notebooks, dashboards, and ML.

## Data sources

### Kaggle CSV

- Dataset: [name and Kaggle link]
- Downloaded: 9/29/2026
- Contents: one row per FBS game, 2002-2025, with scores, quarter scores, and box-score stats (away/home layout)
- Note: seasons 2002-2003 have scores only (no box-score stats) and are excluded from `core`.

The CSV is not in this repo (it's git-ignored). Place it at `data/cfb_data.csv`.

### CollegeFootballData API

- API: [CollegeFootballData.com](https://collegefootballdata.com) (spec saved as `cfbd-openapi.json`)
- Needs a free API key, stored in `.api.env` (git-ignored):
```
   API_BASE_URL=https://api.collegefootballdata.com
   API_KEY=<your key>
```
- Free tier allows 1,000 calls/month. A full 2004-2026 backfill costs ~46 calls for games and ~69 for team seasons.
- Endpoints loaded by `src/ingest_api.py`:

| Mode | Endpoints | Raw table |
|---|---|---|
| `games` | `/games` (regular + postseason) | `raw.api_games` |
| `team_seasons` | `/stats/season`, `/stats/season/advanced`, `/records` | `raw.api_team_seasons` |

Every run is logged to `raw.ingest_log`. Re-running a season upserts, so it's safe to refresh the current season daily.

## Architecture

| Layer | Schema | Description |
|---|---|---|
| Raw | `raw.cfb_games` | CSV loaded as-is, all columns as text |
| Raw | `raw.api_games`, `raw.api_team_seasons` | API responses stored as JSON (`payload jsonb`), one row per record |
| Core | `core.games`, `core.team_games` | Typed, keyed tables; one row per game, and one row per team per game |
| Marts | `marts.team_seasons` | One row per team per season, built from the CSV (records, scoring, box-score averages) |
| Marts | `marts.game_features` | One row per game with pre-game features only (season-to-date, last 5, prior season) + targets |
| Marts | `marts.team_season_stats` | One row per FBS team per season, built from the API (records, scoring, box-score totals, advanced PPA/success-rate/havoc stats) |

## Setup

1. Install Docker Desktop, Python 3.12+, and Git.
2. Copy `.env.example` to `.env` and set a password.
3. Start the database:
```
   docker compose up -d
```
4. Create the Python environment:
```
   python -m venv .venv
   .venv\Scripts\Activate.ps1
   pip install -r requirements.txt
```
5. Load the raw data:
```
   python src\load_raw.py
```
6. Build the core and mart layers by running these against the `cfb` database, in order:
   `sql/02_core.sql`, `sql/03_marts.sql`, `sql/04_game_features.sql`
7. Load the API data (needs `.api.env`, see above):
```
   docker exec cfb-postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /sql/05_raw_api.sql'
   python src\ingest_api.py 2004 2026                # games
   python src\ingest_api.py team_seasons 2004 2026   # season stats + records
```
   With no years, a mode loads the current season only (e.g. `python src\ingest_api.py team_seasons`).
8. Build the API team-season table by running `sql/07_team_season_stats.sql`.

## Project layout

```
docker-compose.yml   Postgres 16 container
src/                 ingestion and feature code
sql/                 numbered build scripts (02_core.sql, ...)
cfbd-openapi.json    CollegeFootballData API spec
sql/Queries/         checks and exploratory queries
notebooks/           analysis notebooks
data/                CSV files (git-ignored)
```

## Data quality notes

- `(game_date, away_team, home_team)` is unique and enforced as a constraint.
- 2020 has only ~568 games (COVID-shortened season).
- `has_stats` flags games with box-score data. Filter on it for models using box-score features.
- `marts.team_season_stats`:
  - Season totals include postseason games. The current season is season-to-date.
  - `sacks` and `tackles_for_loss` exist only from 2016; kick-return stats only from 2005. Earlier seasons are NULL.
  - API naming is confusing for interceptions: `ints_thrown` (API `interceptions`) is by the team's offense, `def_interceptions` (API `passesIntercepted`) is by its defense.
  - `def_*` advanced stats are what the defense allowed, so lower PPA / success rate is better.
  - Cross-check vs `marts.team_seasons` (CSV): W-L matches for 2,577 of 2,581 shared team-seasons.