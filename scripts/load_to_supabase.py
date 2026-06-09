"""
Load the FIFA player data into Supabase Postgres: the ability target (overall)
plus predictors grouped into psychological, technical and physical attributes.

Usage:
    python scripts/load_to_supabase.py
Requires a populated .env (see .env.example) and the schema already created.
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

# predictor groups (DB column names mirror the CSV)
PSYCH = [
    "mentality_composure", "mentality_aggression", "mentality_vision",
    "mentality_positioning", "mentality_penalties", "mentality_interceptions",
    "movement_reactions",
]
TECH = [
    "attacking_crossing", "attacking_finishing", "attacking_heading_accuracy",
    "attacking_short_passing", "attacking_volleys", "skill_dribbling",
    "skill_curve", "skill_fk_accuracy", "skill_long_passing", "skill_ball_control",
    "power_shot_power", "power_long_shots", "defending_marking_awareness",
    "defending_standing_tackle", "defending_sliding_tackle",
]
PHYS = [
    "movement_acceleration", "movement_sprint_speed", "movement_agility",
    "movement_balance", "power_jumping", "power_stamina", "power_strength",
]
PREDICTORS = PSYCH + TECH + PHYS

META = {
    "sofifa_id": "player_id", "short_name": "short_name", "long_name": "long_name",
    "age": "age", "nationality_name": "nationality", "club_name": "club_name",
    "league_name": "league_name", "player_positions": "player_position",
    "overall": "overall", "potential": "potential",
}
COLS = {**META, **{p: p for p in PREDICTORS}}


def get_conn():
    return psycopg2.connect(
        host=os.environ["SUPABASE_DB_HOST"], port=os.environ.get("SUPABASE_DB_PORT", "5432"),
        dbname=os.environ.get("SUPABASE_DB_NAME", "postgres"),
        user=os.environ["SUPABASE_DB_USER"], password=os.environ["SUPABASE_DB_PASSWORD"],
        sslmode="require",
    )


def main():
    if not os.path.exists(CSV_PATH):
        sys.exit(f"Missing {CSV_PATH}. Run scripts/download_data.py first.")

    df = pd.read_csv(CSV_PATH, usecols=list(COLS.keys()), low_memory=False)
    df = df.rename(columns=COLS)
    df["fifa_version"] = FIFA_VERSION
    df["player_position"] = df["player_position"].astype(str).str.split(",").str[0].str.strip()

    for c in ["age", "overall", "potential"] + PREDICTORS:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df = df.dropna(subset=["overall"] + PREDICTORS)

    cols = ["player_id", "short_name", "long_name", "age", "nationality",
            "club_name", "league_name", "player_position", "fifa_version",
            "overall", "potential"] + PREDICTORS
    df = df[cols].where(pd.notnull(df), None)
    rows = [tuple(r) for r in df.itertuples(index=False, name=None)]

    conn = get_conn()
    with conn, conn.cursor() as cur:
        cur.execute("truncate table public.players")
        execute_values(
            cur,
            f"insert into public.players ({','.join(cols)}) values %s",
            rows, page_size=1000,
        )
    conn.close()
    print(f"Loaded {len(rows)} players with {len(PREDICTORS)} predictors into public.players")


if __name__ == "__main__":
    main()
