"""
Load the FIFA player psychological-profile + ability data into Supabase Postgres.

Steps:
 1. Reads data/raw/players_22.csv
 2. Selects the ability target (overall) + mentality/psychological predictors
 3. Cleans rows and upserts into public.players

Usage:
    python scripts/load_to_supabase.py
Requires a populated .env (see .env.example) and the schema already created
(run sql/schema.sql in Supabase first, or scripts/run_schema.py).
"""
import os
import sys
import pandas as pd
import psycopg2
from psycopg2.extras import execute_values
from dotenv import load_dotenv

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
load_dotenv(os.path.join(HERE, ".env"))

CSV_PATH = os.path.join(HERE, "data", "raw", "players_22.csv")
FIFA_VERSION = 22

COLS = {
    "sofifa_id": "player_id",
    "short_name": "short_name",
    "long_name": "long_name",
    "age": "age",
    "nationality_name": "nationality",
    "club_name": "club_name",
    "league_name": "league_name",
    "player_positions": "player_position",
    "overall": "overall",
    "potential": "potential",
    "mentality_composure": "mentality_composure",
    "mentality_aggression": "mentality_aggression",
    "mentality_vision": "mentality_vision",
    "mentality_positioning": "mentality_positioning",
    "mentality_penalties": "mentality_penalties",
    "mentality_interceptions": "mentality_interceptions",
    "movement_reactions": "movement_reactions",
}

PREDICTORS = [
    "mentality_composure", "mentality_aggression", "mentality_vision",
    "mentality_positioning", "mentality_penalties", "mentality_interceptions",
    "movement_reactions",
]


def get_conn():
    return psycopg2.connect(
        host=os.environ["SUPABASE_DB_HOST"],
        port=os.environ.get("SUPABASE_DB_PORT", "5432"),
        dbname=os.environ.get("SUPABASE_DB_NAME", "postgres"),
        user=os.environ["SUPABASE_DB_USER"],
        password=os.environ["SUPABASE_DB_PASSWORD"],
        sslmode="require",
    )


def main():
    if not os.path.exists(CSV_PATH):
        sys.exit(f"Missing {CSV_PATH}. Run scripts/download_data.py first.")

    df = pd.read_csv(CSV_PATH, usecols=list(COLS.keys()), low_memory=False)
    df = df.rename(columns=COLS)
    df["fifa_version"] = FIFA_VERSION

    # only first listed position; drop rows missing the target or any predictor
    df["player_position"] = df["player_position"].astype(str).str.split(",").str[0].str.strip()
    df = df.dropna(subset=["overall"] + PREDICTORS)
    for c in ["age", "overall", "potential"] + PREDICTORS:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna(subset=["overall"] + PREDICTORS)

    cols = [
        "player_id", "short_name", "long_name", "age", "nationality",
        "club_name", "league_name", "player_position", "fifa_version",
        "overall", "potential",
        "mentality_composure", "mentality_aggression", "mentality_vision",
        "mentality_positioning", "mentality_penalties", "mentality_interceptions",
        "movement_reactions",
    ]
    df = df[cols].where(pd.notnull(df), None)
    rows = [tuple(r) for r in df.itertuples(index=False, name=None)]

    conn = get_conn()
    with conn, conn.cursor() as cur:
        execute_values(
            cur,
            f"""insert into public.players ({','.join(cols)}) values %s
                on conflict (player_id) do update set
                  overall = excluded.overall,
                  potential = excluded.potential,
                  mentality_composure = excluded.mentality_composure,
                  mentality_aggression = excluded.mentality_aggression,
                  mentality_vision = excluded.mentality_vision,
                  mentality_positioning = excluded.mentality_positioning,
                  mentality_penalties = excluded.mentality_penalties,
                  mentality_interceptions = excluded.mentality_interceptions,
                  movement_reactions = excluded.movement_reactions""",
            rows,
            page_size=1000,
        )
    conn.close()
    print(f"Loaded {len(rows)} players into public.players")


if __name__ == "__main__":
    main()
