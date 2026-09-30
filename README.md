# College Football Data Pipeline

An end-to-end data science project: raw CSV -> PostgreSQL (Docker) -> SQL modeling -> notebooks, dashboards, and ML.

## Data source

- Dataset: [name and Kaggle link]
- Downloaded: 9/29/2026
- Contents: one row per FBS game, 2002-2025, with scores, quarter scores, and box-score stats (away/home layout)
- Note: seasons 2002-2003 have scores only (no box-score stats) and are excluded from `core`.

The CSV is not in this repo (it's git-ignored). Place it at `data/cfb_data.csv`.

## Architecture

| Layer | Schema | Description |
|---|---|---|
| Raw | `raw.cfb_games` | CSV loaded as-is, all columns as text |
| Core | `core.games`, `core.team_games` | Typed, keyed tables; one row per game, and one row per team per game |
| Marts | (planned) | Rolling team form and model-ready feature tables |

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
6. Build the core layer by running `sql/02_core.sql` against the `cfb` database.

## Project layout

```
docker-compose.yml   Postgres 16 container
src/                 ingestion and feature code
sql/                 numbered build scripts (02_core.sql, ...)
sql/Queries/         checks and exploratory queries
notebooks/           analysis notebooks
data/                CSV files (git-ignored)
```

## Data quality notes

- `(game_date, away_team, home_team)` is unique and enforced as a constraint.
- 2020 has only ~568 games (COVID-shortened season).
- `has_stats` flags games with box-score data. Filter on it for models using box-score features.