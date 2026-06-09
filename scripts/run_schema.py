"""Apply sql/schema.sql to the Supabase Postgres database."""
import os
import psycopg2
from dotenv import load_dotenv

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
load_dotenv(os.path.join(HERE, ".env"))
SCHEMA = os.path.join(HERE, "sql", "schema.sql")


def main():
    with open(SCHEMA, "r", encoding="utf-8") as f:
        sql = f.read()
    conn = psycopg2.connect(
        host=os.environ["SUPABASE_DB_HOST"],
        port=os.environ.get("SUPABASE_DB_PORT", "5432"),
        dbname=os.environ.get("SUPABASE_DB_NAME", "postgres"),
        user=os.environ["SUPABASE_DB_USER"],
        password=os.environ["SUPABASE_DB_PASSWORD"],
        sslmode="require",
    )
    with conn, conn.cursor() as cur:
        cur.execute(sql)
    conn.close()
    print("Schema applied.")


if __name__ == "__main__":
    main()
