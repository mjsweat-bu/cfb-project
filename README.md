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
- Free tier allows 1,000 calls/month. A full 2004-2026 backfill costs ~46 calls for games, ~69 for team seasons, ~92 for player seasons, ~18 per season for plays (~200 for 2016-2026), and ~18 per season for game player box scores (~216 for 2004-2015).
- Endpoints loaded by `src/ingest_api.py`:

| Mode | Endpoints | Raw table |
|---|---|---|
| `games` | `/games` (regular + postseason) | `raw.api_games` |
| `team_seasons` | `/stats/season`, `/stats/season/advanced`, `/records` | `raw.api_team_seasons` |
| `player_seasons` | `/stats/player/season`, `/player/usage`, `/ppa/players/season`, `/roster` | `raw.api_player_seasons` |
| `plays` | `/calendar`, then `/plays` once per week (FBS games) | `raw.api_plays` |
| `game_players` | `/calendar`, then `/games/players` once per week (FBS games) | `raw.api_game_players` |

`/player/season/overview` returns box score + usage + PPA for one player, but needs one call per player per season (~14,000/season). `player_seasons` gets the same data from the bulk endpoints in 4 calls per season.

`plays` and `game_players` skip weeks that are already loaded and ended more than 7 days ago, so a daily run of the current season only refetches recent weeks.

Every run is logged to `raw.ingest_log`. Re-running a season upserts, so it's safe to refresh the current season daily.

## Architecture

| Layer | Schema | Description |
|---|---|---|
| Raw | `raw.cfb_games` | CSV loaded as-is, all columns as text |
| Raw | `raw.api_games`, `raw.api_team_seasons`, `raw.api_player_seasons`, `raw.api_plays`, `raw.api_game_players` | API responses stored as JSON (`payload jsonb`), one row per record |
| Core | `core.games`, `core.team_games` | Typed, keyed tables; one row per game, and one row per team per game |
| Core | `core.player_games` | One row per player per game (2004-2015), typed box-score stats from `/games/players` |
| Core | `core.plays` | Typed play-by-play (2016+), one row per play, with scrimmage flag, run/pass category, offensive yards and success flag |
| Marts | `marts.team_seasons` | One row per team per season, built from the CSV (records, scoring, box-score averages) |
| Marts | `marts.game_features` | One row per game with pre-game features only (season-to-date, last 5, prior season) + targets |
| Marts | `marts.team_season_stats` | One row per FBS team per season, built from the API (records, scoring, box-score totals, advanced PPA/success-rate/havoc stats) |
| Marts | `marts.player_season_stats` | One row per player per team per season, built from the API (bio, passing/rushing/receiving/defense/kicking/return stats, usage, PPA) |
| Marts | `marts.player_career_stats` | One row per player: career totals and rates aggregated from `marts.player_season_stats` (the API has no career endpoint) |
| Marts | `marts.team_season_downs` | One row per FBS team per season (2016+): yards per play, run/pass split, pass rate, distance, success rate and PPA on each down, for offense and defense |

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
   python src\ingest_api.py player_seasons 2004 2026 # player stats, usage, PPA, roster
   python src\ingest_api.py plays 2016 2026          # play-by-play
   python src\ingest_api.py game_players 2004 2015   # per-game player box scores
```
   With no years, a mode loads the current season only (e.g. `python src\ingest_api.py team_seasons`).
8. Build the API tables by running these in order (08 uses 07 and 12):
   `sql/07_team_season_stats.sql`, `sql/12_core_player_games.sql`, `sql/08_player_season_stats.sql`, `sql/09_player_career_stats.sql`, `sql/10_core_plays.sql`, `sql/11_team_season_downs.sql`.
   Run them with `psql -1 -v ON_ERROR_STOP=1 ...` so a failed script rolls back instead of leaving its table dropped.

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
- `marts.player_season_stats`:
  - Keyed on `(season, player_id, team)`; a player who transferred has one row per team.
  - `/stats/player/season` is missing many players before 2016 (8 players in 2004, and e.g. Cam Newton 2010). For 2004-2015, those gaps are filled by summing `core.player_games` (FBS teams only); `stats_source` = `season` or `games` says where a row's box score came from.
  - Usage and PPA start in 2013; defensive box-score stats start in 2016.
  - Usage and PPA exist only for offensive players with plays (~3,000-5,500/season); other players have NULLs there.
  - `class_year` is 1-5 (FR-5th yr). Some roster rows carry the season instead of a class; those are NULL.
- `marts.player_career_stats`:
  - API player IDs are cleaned up first. A gap of 4+ seasons within one ID starts a new career (the API occasionally reuses an ID), shown as `player_id` suffix `-2`. Transfers that got a new ID are merged when name + hometown match, seasons don't overlap, and the span is at most 7 seasons. `player_ids` lists every API ID in a row.
  - Careers starting before 2009 are incomplete (thin API coverage), and 2026 careers are in progress.
  - Per-play PPA can't be summed, so the career table has PPA totals plus `best_season_ppa_avg`.
- `core.plays` / `marts.team_season_downs`:
  - Loaded from 2016 on. Earlier seasons exist in the API but cost ~18 calls each.
  - Scrimmage plays only (down 1-4, run or pass); penalties, kicks, timeouts and 2-pt tries are excluded.
  - Sacks count as pass plays (analytics convention; official college stats count them as rushes).
  - Interceptions and fumble-return TDs count as 0 offensive yards, because the API's `yardsGained` on those plays is the defense's return.
  - Success rate: gain of at least 50% of the distance on 1st down, 70% on 2nd, 100% on 3rd/4th.
  - Includes postseason and garbage time.
