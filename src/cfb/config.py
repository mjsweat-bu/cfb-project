"""Project paths and settings, in one place.

Secrets stay in .env (database) and .api.env (API key) at the project root;
both are git-ignored and loaded here, so scripts and notebooks can run from
any working directory.
"""
import os
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[2]
load_dotenv(ROOT / ".env")
load_dotenv(ROOT / ".api.env")

# folders
SQL_BUILD_DIR = ROOT / "sql" / "build"          # pipeline scripts, run in numeric order
SQL_ANALYSIS_DIR = ROOT / "sql" / "analysis"    # ad-hoc and report queries
MODELS_DIR = ROOT / "models"                    # trained model files (git-ignored)

# database (Postgres in Docker; see docker-compose.yml)
DB_CONTAINER = "cfb-postgres"
DB_CONTAINER_SQL_DIR = "/sql"                   # ./sql is mounted here in the container
DB_HOST = os.environ.get("POSTGRES_HOST", "localhost")
DB_PORT = int(os.environ.get("POSTGRES_PORT", "5432"))
DB_NAME = os.environ.get("POSTGRES_DB")
DB_USER = os.environ.get("POSTGRES_USER")
DB_PASSWORD = os.environ.get("POSTGRES_PASSWORD")

# CollegeFootballData API
API_BASE_URL = os.environ.get("API_BASE_URL", "https://api.collegefootballdata.com").rstrip("/")
API_KEY = os.environ.get("API_KEY")
