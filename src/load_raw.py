import os
from pathlib import Path
import csv
import psycopg2

CSV_PATH = Path("data/cfb_data.csv")

# read DB credentials from .env
env = {}
for line in Path(".env").read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        env[k] = v

with open(CSV_PATH, newline="", encoding="utf-8-sig") as f:
    header = next(csv.reader(f))

cols_sql = ",\n    ".join(f'"{c}" TEXT' for c in header)

conn = psycopg2.connect(
    host="localhost", port=5432,
    dbname=env["POSTGRES_DB"],
    user=env["POSTGRES_USER"],
    password=env["POSTGRES_PASSWORD"],
)
conn.autocommit = False
cur = conn.cursor()

cur.execute("CREATE SCHEMA IF NOT EXISTS raw;")
cur.execute("DROP TABLE IF EXISTS raw.cfb_games;")
cur.execute(f"CREATE TABLE raw.cfb_games (\n    {cols_sql}\n);")

with open(CSV_PATH, newline="", encoding="utf-8-sig") as f:
    cur.copy_expert(
        "COPY raw.cfb_games FROM STDIN WITH (FORMAT csv, HEADER true)", f
    )

cur.execute("SELECT count(*) FROM raw.cfb_games;")
print("Rows loaded:", cur.fetchone()[0])
print("Columns:", len(header))
conn.commit()
conn.close()
