"""Population step B8: recipe embeddings.

The embedded text comes only from fn_recipe_embedding_source. A recipe is
re-embedded only when the SHA-256 of that text, or the model name, differs
from what is stored, so a second run recomputes nothing.
"""
import hashlib

import psycopg2
from sentence_transformers import SentenceTransformer

MODEL = "all-MiniLM-L6-v2"


def main():
    conn = psycopg2.connect()
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "SELECT r.recipe_id, fn_recipe_embedding_source(r.recipe_id), e.content_hash, e.model_name "
                "FROM recipes r LEFT JOIN recipe_embeddings e ON e.recipe_id = r.recipe_id ORDER BY r.recipe_id")
            rows = cur.fetchall()
        todo = []
        for rid, text, stored_hash, stored_model in rows:
            digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
            if digest != stored_hash or stored_model != MODEL:
                todo.append((rid, text, digest))
        print(f"recipes: {len(rows)}, to embed: {len(todo)}, skipped: {len(rows) - len(todo)}")
        if todo:
            model = SentenceTransformer(f"sentence-transformers/{MODEL}")
            vectors = model.encode([t for _, t, _ in todo], normalize_embeddings=True, batch_size=32)
            with conn, conn.cursor() as cur:
                cur.executemany(
                    "INSERT INTO recipe_embeddings (recipe_id, embedding_source_text, embedding, "
                    "model_name, model_dim, content_hash) VALUES (%s, %s, %s::vector, %s, 384, %s) "
                    "ON CONFLICT (recipe_id) DO UPDATE SET "
                    "embedding_source_text = EXCLUDED.embedding_source_text, "
                    "embedding = EXCLUDED.embedding, model_name = EXCLUDED.model_name, "
                    "content_hash = EXCLUDED.content_hash, generated_at = now()",
                    [(rid, text, "[" + ",".join(f"{x:.7f}" for x in vec) + "]", MODEL, digest)
                     for (rid, text, digest), vec in zip(todo, vectors)])
        with conn, conn.cursor() as cur:
            cur.execute("ANALYZE recipe_embeddings")
            cur.execute("ANALYZE recipes")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
