"""Embeds a natural-language query and logs it to search_queries.

Usage: python scripts/log_query.py "something warming for a cold evening"
The stored query_embedding can then be passed to fn_search_recipes from
plain SQL. Uses the same model as recipe ingestion.
"""
import json
import sys

import psycopg2
from sentence_transformers import SentenceTransformer


def main():
    text = sys.argv[1]
    vec = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2").encode(text, normalize_embeddings=True)
    literal = "[" + ",".join(f"{x:.7f}" for x in vec) + "]"
    conn = psycopg2.connect()
    try:
        with conn, conn.cursor() as cur:
            cur.execute("SELECT recipe_id, title, similarity FROM fn_search_recipes(%s::vector, p_limit := 5)",
                        (literal,))
            rows = cur.fetchall()
            cur.execute("SELECT sp_log_search(NULL, %s, %s::vector, %s::jsonb, %s, %s)",
                        (text, literal, json.dumps({}), len(rows), rows[0][0] if rows else None))
            print(f"query_id {cur.fetchone()[0]}")
            for rid, title, sim in rows:
                print(f"{sim}  {rid}  {title}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
