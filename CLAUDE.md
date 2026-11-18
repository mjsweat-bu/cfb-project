# cfb-project

## Database: stays on local Docker Postgres (decision, 2026-11-18)
- Keep using the `cfb-postgres` Docker container (`docker compose up -d`). Do not move this
  project to Neon or another hosted database, add DATABASE_URL support, or remove the Docker
  dependency unless the owner asks for it.
- Cloud Claude sessions can't reach this database, so work there is limited to code changes
  and tests that don't need data.
