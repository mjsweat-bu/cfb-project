"""Data checks against the built database. Skipped when the database is down.

    pytest            (from the project root)
"""
import pytest
from sqlalchemy import text

from cfb.checks import CHECKS
from cfb.db import engine


def _db_available():
    try:
        with engine.connect():
            return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(not _db_available(), reason="database not reachable (docker compose up -d)")


@pytest.mark.parametrize("name,description,sql", CHECKS, ids=[c[0] for c in CHECKS])
def test_check(name, description, sql):
    with engine.connect() as conn:
        bad = conn.execute(text(sql)).scalar()
    assert bad == 0, f"{description}: {bad} bad"
