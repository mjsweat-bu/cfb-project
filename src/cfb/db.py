"""Database access shared by scripts and notebooks.

    from cfb.db import engine, read_query
    df = read_query("weekly_recap_box.sql", team="Auburn", season=2026, week=5)
"""
import re
from pathlib import Path

import pandas as pd
import psycopg2
from sqlalchemy import create_engine

from cfb import config

engine = create_engine(
    f"postgresql+psycopg2://{config.DB_USER}:{config.DB_PASSWORD}"
    f"@{config.DB_HOST}:{config.DB_PORT}/{config.DB_NAME}"
)


def get_conn():
    """A raw psycopg2 connection (for bulk inserts in the ingest script)."""
    return psycopg2.connect(
        host=config.DB_HOST, port=config.DB_PORT,
        dbname=config.DB_NAME, user=config.DB_USER, password=config.DB_PASSWORD,
    )


def sql_literal(value):
    """A Python value as a SQL literal for a params CTE (text or integer)."""
    if isinstance(value, str):
        return "'" + value.replace("'", "''") + "'::text"
    return str(int(value))


def read_sql_file(path, **params):
    """The text of a .sql file. Keyword arguments replace the values in its
    `params` CTE (the first `params AS ( SELECT ... )` block), so the file
    still runs on its own in a SQL editor with its default values."""
    sql = Path(path).read_text()
    if params:
        cols = ", ".join(f"{sql_literal(v)} AS {k}" for k, v in params.items())
        sql, n = re.subn(r"params AS \(\s*SELECT .*?\n\)", f"params AS (\n    SELECT {cols}\n)",
                         sql, count=1, flags=re.S)
        if n != 1:
            raise ValueError(f"{path}: no params CTE to replace")
    return sql


def read_query(name, **params):
    """Run a sql/analysis file and return a DataFrame. See read_sql_file for params."""
    sql = read_sql_file(config.SQL_ANALYSIS_DIR / name, **params)
    # "%" doubled because psycopg2 treats it as a parameter marker (LIKE '%...')
    return pd.read_sql(sql.replace("%", "%%"), engine)
