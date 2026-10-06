# College Football Data Pipeline

An end-to-end data science project: CollegeFootballData API -> PostgreSQL (Docker) -> SQL modeling -> notebooks, dashboards, and ML.

## Data sources

All data comes from the CollegeFootballData API. (The project started from a Kaggle CSV of
2002-2025 games; that pipeline was retired in favor of the API.)

- API: [CollegeFootballData.com](https://collegefootballdata.com) (spec saved as `cfbd-openapi.json`)
- Needs a free API key, stored in `.api.env` (git-ignored):
```
   API_BASE_URL=https://api.collegefootballdata.com
   API_KEY=<your key>
```
- Free tier allows 1,000 calls/month. A full 2004-2026 backfill costs ~46 calls for games, ~69 for team seasons, ~92 for player seasons, ~18 per season for plays (~460 for 2001-2026), ~18 per season for game player box scores (~216 for 2004-2015), ~18 per season for team box scores (~420 for 2004-2026), and 2 per season for betting lines.
- Endpoints loaded by `src/ingest_api.py`:

| Mode | Endpoints | Raw table |
|---|---|---|
| `games` | `/games` (regular + postseason) | `raw.api_games` |
| `team_seasons` | `/stats/season`, `/stats/season/advanced`, `/records` | `raw.api_team_seasons` |
| `player_seasons` | `/stats/player/season`, `/player/usage`, `/ppa/players/season`, `/roster` | `raw.api_player_seasons` |
| `plays` | `/calendar`, then `/plays` once per week (FBS games) | `raw.api_plays` |
| `game_players` | `/calendar`, then `/games/players` once per week (FBS games) | `raw.api_game_players` |
| `game_teams` | `/calendar`, then `/games/teams` once per week (FBS games) | `raw.api_game_teams` |
| `lines` | `/lines` (regular + postseason, all providers; data starts in 2013) | `raw.api_lines` |

`/player/season/overview` returns box score + usage + PPA for one player, but needs one call per player per season (~14,000/season). `player_seasons` gets the same data from the bulk endpoints in 4 calls per season.

`plays`, `game_players` and `game_teams` skip weeks that are already loaded and ended more than 7 days ago, so a daily run of the current season only refetches recent weeks.

Every run is logged to `raw.ingest_log`. Re-running a season upserts, so it's safe to refresh the current season daily.

## Architecture

| Layer | Schema | Description |
|---|---|---|
| Raw | `raw.api_games`, `raw.api_team_seasons`, `raw.api_player_seasons`, `raw.api_plays`, `raw.api_game_players`, `raw.api_game_teams`, `raw.api_lines` | API responses stored as JSON (`payload jsonb`), one row per record |
| Core | `core.games` | One row per completed game with at least one FBS team (2004+): date, venue, teams, classification, conference, score, quarter and OT scores, pregame Elo. `game_id` is the API's game ID, shared by every game-level table |
| Core | `core.team_games` | One row per team per game: result, opponent, location, pregame Elo, official box score (`/games/teams`: first downs, 3rd/4th down, passing, rushing, turnovers, penalties, possession) for both sides, plus offense/defense PPA and success rate from `core.plays` and drive stats (drives, scoring drives, three-and-outs, points per drive, starting field position) from `core.drives` |
| Core | `core.player_games` | One row per player per game (2004-2015), typed box-score stats from `/games/players` |
| Core | `core.plays` | Typed play-by-play (2001+, ~3.4M plays), one row per play, with scrimmage flag, run/pass category, offensive yards and success flag |
| Core | `core.drives` | One row per offensive possession (2001+), built from `core.plays`: start/end field position and clock, start score margin, plays, yards, PPA, 3rd/4th-down conversions, result (TD, FG, punt, INT, fumble, downs, ...), three-and-out flag, and the team's possession number in the game |
| Core | `core.game_lines` | Betting lines (2013+), one row per game per provider: spread and total (open and close), moneylines, and ATS / over-under results. Spreads are from the home side (-7 = home favored by 7) |
| Core | `core.game_spreads` | One line per game: the `consensus` provider where the API has it (through 2022), otherwise the median across providers |
| Marts | `marts.game_features` | One row per game with pre-game features only (pregame Elo, season-to-date box score and PPA, last 5 games, prior season, closing spread) + targets |
| Marts | `marts.play_features` | One row per scrimmage snap (2008+, ~2.1M rows) for a drive-scoring model that can be re-scored live: situation before the snap (down, distance, field position, seconds left in the half, score margin), the drive so far, both teams' season-to-date strength (PPA, points per drive, Elo, spread), and the target `drive_scored`. Every feature has an equivalent in the API's `/live/plays` feed |
| Marts | `marts.team_season_stats` | One row per FBS team per season, built from the API (records, scoring, box-score totals, advanced PPA/success-rate/havoc stats) |
| Marts | `marts.player_season_stats` | One row per player per team per season, built from the API (bio, passing/rushing/receiving/defense/kicking/return stats, usage, PPA) |
| Marts | `marts.player_career_stats` | One row per player: career totals and rates aggregated from `marts.player_season_stats` (the API has no career endpoint) |
| Marts | `marts.team_season_downs` | One row per FBS team per season (2004+, where the FBS team list starts): yards per play, run/pass split, pass rate, distance, success rate and PPA on each down, for offense and defense |

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
5. Create the helper functions and raw tables:
```
   docker exec cfb-postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /sql/01_functions.sql -f /sql/02_raw_api.sql'
```
6. Load the API data (needs `.api.env`, see above):
```
   python src\ingest_api.py 2004 2026                # games
   python src\ingest_api.py team_seasons 2004 2026   # season stats + records
   python src\ingest_api.py player_seasons 2004 2026 # player stats, usage, PPA, roster
   python src\ingest_api.py plays 2001 2026          # play-by-play
   python src\ingest_api.py game_players 2004 2015   # per-game player box scores
   python src\ingest_api.py game_teams 2004 2026     # per-game team box scores
   python src\ingest_api.py lines 2004 2026          # betting lines
```
   With no years, a mode loads the current season only (e.g. `python src\ingest_api.py team_seasons`).
7. Build the tables by running the scripts in numeric order (core before marts; each script lists what it needs in its header):
   `sql/03_core_games.sql`, `sql/04_core_plays.sql`, `sql/05_core_drives.sql`, `sql/06_core_team_games.sql`, `sql/07_core_player_games.sql`, `sql/08_core_game_lines.sql`, `sql/09_team_season_stats.sql`, `sql/10_team_season_downs.sql`, `sql/11_player_season_stats.sql`, `sql/12_player_career_stats.sql`, `sql/13_game_features.sql`, `sql/14_play_features.sql`.
   Run them with `psql -1 -v ON_ERROR_STOP=1 ...` so a failed script rolls back instead of leaving its table dropped.

### Refreshing the current season

After each game week, run:
```
   python src\refresh.py
```
It loads the current season from every API mode except `game_players` (~17 calls), rebuilds all scripts in numeric order (skipping `07`, whose 2004-2015 data doesn't change) and prints the latest week in `core.games`. It stops at the first error. Options: `--season 2025`, `--skip-load` (rebuild only, no API calls), `--full-rebuild` (include `07`). Running it again a few days later picks up stat corrections, because `plays` and `game_teams` refetch any week that ended in the last 7 days.

## Project layout

```
docker-compose.yml   Postgres 16 container
src/                 ingestion and feature code
sql/                 numbered build scripts (01_functions.sql, ...)
cfbd-openapi.json    CollegeFootballData API spec
sql/Queries/         checks and exploratory queries
notebooks/           analysis notebooks
```

## Analysis queries and notebooks

Ad-hoc analysis lives in `sql/Queries/` (read-only queries against the built tables) and
`notebooks/` (charts). Notebooks read the `.sql` files directly, so editing a query changes the
notebook's data on the next run.

### Queries (`sql/Queries/`)

Most queries start with a `params` CTE (season, conference, highlighted team, minimum games) so
they can be re-pointed without editing the logic.

| File | What it returns | Source |
|---|---|---|
| `sec_team_third_down.sql` | Team offense by conference/season: 3rd-down plays, conversion rate, distance and yards gained, split by pass/rush (conversions, rate, avg yards to go); play calling; plays and drives per game/half/quarter; plays per drive by half/quarter; yards per drive | `core.plays`, `core.drives` |
| `sec_team_ppa.sql` | Team offense and defense by conference/season: PPA (EPA) per play and total, split by pass/rush, success rate and explosiveness (PPA on successful plays), strength of schedule (opponents' season averages, leave-one-out) and opponent-adjusted PPA overall/pass/rush, plus net adjusted PPA (offense minus defense); garbage time excluded | `core.plays` |
| `auburn_defense_player_ppa.sql` | One team's defenders for a season: average PPA of the plays each made (tackles, sacks, INTs, PBUs, hurries, forced/recovered fumbles parsed from play text), vs. team average, run/pass tackle PPA, TFLs, stop %, havoc plays; roster name and position. Only games in the ESPN "(#nn Name)" text format are picked up | `core.plays`, `raw.api_player_seasons` |
| `sec_linebacker_ppa.sql` | Conference-wide version of `auburn_defense_player_ppa.sql` for one roster position (default LB): every player's PPA on plays made, vs. own-team average, tackles by run/pass, TFLs, stop %, sacks/INTs/PBUs, havoc plays, with ranks and each team's tackler-parse coverage | `core.plays`, `raw.api_player_seasons` |
| `sec_offensive_line.sql` | O-line as a unit by conference/season: line yards per rush, stuff %, power success %, second-level / open-field yards, run blocking by direction (left/middle/right), sack rate, pressure rate (sacks + hurries), O-line penalties per game, with conference ranks | `core.plays`, `raw.api_player_seasons` |
| `sec_offensive_line_players.sql` | Individual offensive linemen: accepted penalties by type (holding, pre-snap, other), penalty yards, gains and TDs called back, 3rd/4th-down penalties, per-100-snap rate; roster bio. Penalties are the only per-lineman stat in play-by-play | `core.plays`, `raw.api_player_seasons` |
| `sec_scoring_drive_conversions.sql` | 3rd/4th-down attempts and conversions on scoring (TD/FG) vs non-scoring drives, by team plus a conference total row | `core.drives` |
| `sec_interception_drives.sql` | Two queries. (1) One row per team for its main QB (most pass plays): INTs per 100 passes, pick-sixes, return yards, play # in drive, passes/rushes/sacks before the INT, down and distance, field position, score/clock situation. (2) Every interception with passer, down & distance, drive context and play text | `core.plays` |
| `first_possession_three_and_out.sql` | All-time (2001+) FBS ranking: how often a team's first possession of a game is a three-and-out punt | `core.drives`, `marts.team_season_stats` |
| `three_and_outs.sql` | All-time FBS ranking of three-and-outs on any drive: totals, per game, % of drives, plus one column per season 2016-2026. Filter by conference (current members, or only seasons spent in the conference) | `core.drives`, `marts.team_season_stats` |
| `qb_third_down.sql` | 3rd-down distance, yards gained and conversion rate per QB (QB plays matched from play text) | `core.plays`, `marts.player_season_stats` |
| `Auburn_QBs.sql` | Auburn QBs with Auburn-only passing/rushing totals | `marts.player_season_stats` |
| `weekly_season_so_far.sql` | A team's regular season through a week: result, score, closing spread and ATS result, yards, PPA, turnovers | `core.team_games`, `core.game_spreads` |
| `weekly_recap_box.sql` | One game, one row per stat: team vs. opponent plus the team's average coming in (points, yards, yards/play, 3rd downs, turnovers, penalties, possession, PPA, success rate, points per drive, three-and-outs, starting field position) | `core.team_games` |
| `weekly_recap_drives.sql` | Every drive of one game, both teams: quarter, clock, start, plays, yards, result, score before, 3rd downs, PPA; field position as numbers for a drive chart | `core.drives` |
| `weekly_recap_quarters.sql` | One game by quarter, both offenses: plays, yards/play, success rate, PPA, pass rate, 20+ yard plays | `core.plays` |
| `weekly_preview_game.sql` | The team's next game after a week (skips byes; works for past weeks too): kickoff, site, venue, spread and total | `raw.api_games`, `core.game_spreads` |
| `weekly_preview_matchup.sql` | Team vs. next opponent, season to date, offense / defense / overall, with FBS ranks (1 = best) | `core.team_games`, `raw.api_games` |
| `test.sql` | Row-count and sanity checks for the game-level tables (expected values in comments) | `core.games`, `core.team_games`, `marts.game_features` |

Shared definitions used by the play-by-play queries:
- **Plays** are scrimmage plays (`core.plays.is_scrimmage`); penalties, timeouts and kicks are not plays. Sacks count as pass plays.
- **Drives** come from `core.drives`: one row per possession, keyed on `(drive_id, offense)` because the API files the kickoff under the same `drive_id` as the receiving team's possession. Queries that need at least one snap filter on `plays > 0`.
- **Three-and-out** = the team's 4th counted play on a drive is a punt (penalties don't count toward the 4 plays).
- **QB names** come from the play text (`#12 A.Daniels pass ...` or `Hank Brown pass ...`, normalized to `A.Daniels`), since plays carry no player IDs.
- **FBS** = team-seasons in `marts.team_season_stats` (2004+); 2001-2003 use each team's 2004 status.
- **PPA** (predicted points added) is the API's name for EPA: expected points after a play minus before it. Offense: higher is better. Defense (`def_` columns, defenders' plays): it's the offense's PPA allowed, so lower is better. Compare within a season; the FBS average has drifted up (~0.05/play in 2005-09, ~0.12 in the 2020s).
- **Garbage time** (excluded in the PPA, defender and O-line queries): score margin > 38 in Q2, > 28 in Q3, > 22 in Q4.
- **Opponent adjustment** (`sec_team_ppa.sql`): each opponent's season average over all FBS games, leaving out its plays against the team being rated; play PPA minus that, plus the FBS average = PPA against an average opponent.
- **Defenders and linemen** come from the play text, since plays carry no player IDs: tacklers in parentheses (`(#17 X.Atkins; #1 C.Anthony)`), `intercepted / broken up / hurried / forced by #nn Name`, and `PENALTY AUB Holding (#72 C.Best)`. They are matched to `/roster` on last name + jersey, falling back to last name + first initial (jerseys sometimes differ from the roster). Only games in the ESPN `#nn Name` format are covered; Auburn's 2025 weeks 1-8, for example, use full names without jerseys. `team_tackler_pct` / `team_text_pct` show coverage.
- **Defender PPA is position-biased**: safeties and corners usually tackle after a completion has gained yards, so compare within a position group and use stop %, TFLs and havoc plays alongside it.
- **Offensive line** has no per-player blocking data; it's graded as a unit (line yards: losses x1.2, 0-4 yds x1, 5-10 x0.5, 11+ x0; stuff %, power %, sack and pressure rate). Penalties are the only per-lineman stat, and with no snap counts only penalized linemen appear. Run direction is where the runner ended up ("rush left/middle/right"), not the designed gap.

### Notebooks (`notebooks/`)

| Notebook | Query | Charts |
|---|---|---|
| `SEC_third_downs.ipynb` | `sec_team_third_down.sql`, `sec_scoring_drive_conversions.sql` | 3rd-down conversion vs total 3rd-down plays (overall/pass/rush); passing vs rushing vs overall conversion dot plot with SEC average and play counts; 1st vs 2nd half plays per drive sized by 3rd-down plays; scoring vs non-scoring drive conversion |
| `sec_interceptions.ipynb` | `sec_interception_drives.sql` | Main QBs: play in drive vs drive yards before the INT; one dot per QB: avg yards to go vs avg play in drive (sized by INTs); **QB INT grade** (0-100: 50% INT rate, 30% costly INTs, 20% unforced INTs, each per 100 passes and scaled best = 100 to worst = 0) as a report card, INT-type breakdown and rate-vs-volume scatter |
| `auburn_qbs.ipynb` | `Auburn_QBs.sql` | Passing vs rushing yards per Auburn QB |
| `auburn_defense_ppa.ipynb` | `auburn_defense_player_ppa.sql`, `sec_linebacker_ppa.sql` | Auburn defenders: plays made vs average PPA on those plays, colored by position group (shape = position) with the team average line; Auburn LBs highlighted against all SEC LBs (plays per game vs average PPA, SEC medians, conference ranks) |
| `auburn_offensive_line.ipynb` | `sec_offensive_line.sql`, `sec_offensive_line_players.sql` | Auburn linemen's penalties by type with yards cost; SEC linemen with the costliest penalties (penalty yards + gains called back); Auburn vs SEC on line yards, stuff %, power %, sack %, pressure % and O-line penalties (small multiples); run direction scatters vs the SEC: share of runs vs line yards for left/middle/right (dot size = runs), and left- vs right-side line yards per team |
| `weekly_report.ipynb` | the six `weekly_*.sql` files | Template: set `TEAM`, `SEASON`, `WEEK` (default = latest game) and run all. Recap of the game (box score vs. the team's average coming in, drive chart, success rate by quarter) and preview of the next opponent (line, offense-vs-defense matchup tables, FBS-rank dumbbell chart). `read_query(name, **params)` overwrites each file's `params` CTE |

Notebook notes:
- Select the `.venv` kernel and make sure the database container is running (`docker compose up -d`).
- Queries containing `%` (e.g. `ILIKE '%intercept%'`) must be escaped as `%%` before `pd.read_sql`, because psycopg2 treats `%` as a parameter placeholder.
- Don't wrap queries in SQLAlchemy `text()`: regexes such as `(?:Jr\.)` look like `:Jr` bind parameters. The newer notebooks use a `read_query()` helper that reads the file and doubles `%`.
- `.sql` files with two queries are split on their `-- ---------- 2.` marker and each part loaded separately.
- If a notebook is changed on disk while open in VS Code, use **File: Revert File** to load the new version (saving the open copy overwrites it).

## Data quality notes

- Betting lines (`core.game_lines`, `core.game_spreads`):
  - The API has lines only from 2013; earlier games return an empty `lines` array and drop out.
  - Spreads are from the home side (-7 = home favored by 7). `ats_result` / `ou_result` are NULL until the game is final.
  - The `consensus` provider runs through 2022; from 2023 `core.game_spreads` uses the median across providers (Bovada, DraftKings, ESPN Bet), so 2-provider games can show values like -42.75.
  - Individual providers occasionally have the spread sign flipped (e.g. ESPN Bet, Auburn at Baylor 2025), so prefer `core.game_spreads` to filtering one book.

- `core.games` / `core.team_games`:
  - Only completed games with at least one FBS team; FCS teams appear only in their games against FBS teams.
  - 2020 has only ~534 FBS-vs-FBS games (COVID-shortened season).
  - `has_stats` flags team-games with an official box score, `has_pbp` those with play-by-play. Filter on them for models using box-score or PPA features.
  - Box scores match the retired Kaggle CSV on 99.7% of 2004-2010 team-games (points, yards, turnovers, penalties).
  - `pregame_elo` is missing for ~8% of games, mostly against FCS teams.
  - `possession_sec` is incomplete in the API before 2012: the two teams add up to ~37 minutes per game (2004-2011) instead of 60, so compare possession across eras as a share of the game, not raw minutes. (The retired CSV had the same gap.)
- `marts.team_season_stats`:
  - Season totals include postseason games. The current season is season-to-date.
  - `sacks` and `tackles_for_loss` exist only from 2016; kick-return stats only from 2005. Earlier seasons are NULL.
  - API naming is confusing for interceptions: `ints_thrown` (API `interceptions`) is by the team's offense, `def_interceptions` (API `passesIntercepted`) is by its defense.
  - `def_*` advanced stats are what the defense allowed, so lower PPA / success rate is better.
  - Cross-checked against the retired Kaggle CSV: W-L matched for 2,577 of 2,581 shared team-seasons.
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
  - Loaded for 2001-2026, everything the API has (it returns no plays before 2001).
  - Early seasons are incomplete in the API: 2002 has only 31 games (mostly bowls), and 2001-2004 have ~420-480 games vs ~850+ from 2011 on. 2001 week 4 is empty (games postponed after 9/11).
  - The API has no `/calendar` for 2001; the loader falls back to regular weeks 1-16 plus the postseason for any past season without a calendar.
  - Scrimmage plays only (down 1-4, run or pass); penalties, kicks, timeouts and 2-pt tries are excluded.
  - Sacks count as pass plays (analytics convention; official college stats count them as rushes).
  - Interceptions and fumble-return TDs count as 0 offensive yards, because the API's `yardsGained` on those plays is the defense's return.
  - The API's `offenseScore` / `defenseScore` are the score **after** the play (a TD row already includes the 7). `pre_offense_score` / `pre_defense_score` carry the score before the snap, from the previous play in the game; use them for anything describing the situation at the snap (`core.drives` start scores and `marts.play_features` do).
  - Success rate: gain of at least 50% of the distance on 1st down, 70% on 2nd, 100% on 3rd/4th.
  - Includes postseason and garbage time.
