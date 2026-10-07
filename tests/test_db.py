"""Unit tests for cfb.db helpers (no database needed)."""
import pytest

from cfb.db import read_sql_file, sql_literal

SQL = """-- example
WITH params AS (
    SELECT 'Auburn'::text AS team, 2026 AS season
),
x AS (SELECT 1)
SELECT * FROM params
"""


def test_sql_literal():
    assert sql_literal("Auburn") == "'Auburn'::text"
    assert sql_literal("Texas A&M") == "'Texas A&M'::text"
    assert sql_literal("Hawai'i") == "'Hawai''i'::text"    # quotes escaped
    assert sql_literal(2026) == "2026"


def test_params_replaced(tmp_path):
    f = tmp_path / "q.sql"
    f.write_text(SQL)
    out = read_sql_file(f, team="Georgia", season=2025)
    assert "SELECT 'Georgia'::text AS team, 2025 AS season" in out
    assert "Auburn" not in out
    assert "x AS (SELECT 1)" in out          # the rest of the query is untouched


def test_no_params_leaves_file_alone(tmp_path):
    f = tmp_path / "q.sql"
    f.write_text(SQL)
    assert read_sql_file(f) == SQL


def test_missing_params_cte_raises(tmp_path):
    f = tmp_path / "q.sql"
    f.write_text("SELECT 1")
    with pytest.raises(ValueError):
        read_sql_file(f, team="Auburn")
