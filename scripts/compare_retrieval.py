"""Population step B9: lexical full-text vs vector retrieval, precision at 5.

Usage:
  python scripts/compare_retrieval.py candidates   # prints the pooled top-5s to judge
  python scripts/compare_retrieval.py score        # scores against seed/relevance_judgments.json

Lexical retrieval uses the GIN-indexed tsvector with an OR query ranked by
ts_rank (an AND query returns almost nothing for intent phrasing). Vector
retrieval uses fn_search_recipes with no filters. Results are written to
results/retrieval_comparison.csv.
"""
import csv
import json
import sys
from pathlib import Path

import psycopg2
from sentence_transformers import SentenceTransformer

ROOT = Path(__file__).resolve().parents[1]
QUERIES = [
    "quick high-protein dinner without dairy",
    "something warming for a cold evening",
    "light lunch that won't make me sleepy",
    "hearty vegan comfort food",
    "something fresh for a hot day",
    "cosy weekend bake",
    "post-workout meal",
    "easy on the stomach",
    "sweet breakfast to start the day",
    "spicy dish with a kick",
]
FTS = "to_tsvector('english', title || ' ' || COALESCE(description, '') || ' ' || COALESCE(cuisine, ''))"


def lexical(cur, q):
    cur.execute(
        "WITH q AS (SELECT NULLIF(replace(plainto_tsquery('english', %s)::text, '&', '|'), '')::tsquery AS tq) "
        f"SELECT r.recipe_id FROM recipes r, q WHERE r.is_published AND {FTS} @@ q.tq "
        f"ORDER BY ts_rank({FTS}, q.tq) DESC, r.recipe_id LIMIT 5", (q,))
    return [r[0] for r in cur.fetchall()]


def vector(cur, emb):
    cur.execute("SELECT recipe_id FROM fn_search_recipes(%s::vector, p_limit := 5)", (emb,))
    return [r[0] for r in cur.fetchall()]


def run(cur):
    model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
    embs = model.encode(QUERIES, normalize_embeddings=True)
    return {q: (lexical(cur, q), vector(cur, "[" + ",".join(f"{x:.7f}" for x in e) + "]"))
            for q, e in zip(QUERIES, embs)}


def main():
    mode = sys.argv[1]
    conn = psycopg2.connect()
    try:
        with conn, conn.cursor() as cur:
            results = run(cur)
            if mode == "candidates":
                for q, (lex, vec) in results.items():
                    print(f"## {q}")
                    cur.execute(
                        "SELECT r.recipe_id, r.title, left(r.description, 90), "
                        "r.prep_time_min + r.cook_time_min, round(r.total_protein_g / r.servings), "
                        "round(r.total_calories / r.servings), "
                        "(SELECT string_agg(t.tag_name, ',') FROM recipe_dietary_tags x "
                        " JOIN dietary_tags t ON t.tag_id = x.tag_id WHERE x.recipe_id = r.recipe_id "
                        " AND t.tag_name IN ('vegan','contains_dairy')) "
                        "FROM recipes r WHERE r.recipe_id = ANY(%s) ORDER BY r.recipe_id",
                        (sorted(set(lex) | set(vec)),))
                    for row in cur.fetchall():
                        src = ("L" if row[0] in lex else "") + ("V" if row[0] in vec else "")
                        print(src, *row, sep="|")
                return
            judged = json.loads((ROOT / "seed" / "relevance_judgments.json").read_text())
            out = ROOT / "results"
            out.mkdir(exist_ok=True)
            with open(out / "retrieval_comparison.csv", "w", newline="") as f:
                w = csv.writer(f)
                w.writerow(["query", "lexical_hits", "lexical_p_at_5", "vector_p_at_5",
                            "lexical_top5", "vector_top5"])
                tot_l = tot_v = 0
                for q, (lex, vec) in results.items():
                    rel = set(judged[q])
                    pl, pv = sum(r in rel for r in lex) / 5, sum(r in rel for r in vec) / 5
                    tot_l, tot_v = tot_l + pl, tot_v + pv
                    w.writerow([q, len(lex), pl, pv, " ".join(map(str, lex)), " ".join(map(str, vec))])
                    print(f"{pl:.1f}  {pv:.1f}  {q}")
                w.writerow(["mean", "", round(tot_l / len(QUERIES), 2), round(tot_v / len(QUERIES), 2), "", ""])
                print(f"mean lexical {tot_l / len(QUERIES):.2f}, vector {tot_v / len(QUERIES):.2f}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
