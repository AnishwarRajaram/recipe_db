# Database Layer — Semantic Recipe Discovery Platform

Run in numbered order. Forward-only, safe to re-run. Connection settings come
from the standard `PG*` environment variables (see `db.env.example`).

```bash
psql -v ON_ERROR_STOP=1 -f 000_complete_schema.sql
psql -v ON_ERROR_STOP=1 -f 009_search_and_staleness_fixes.sql
psql -v ON_ERROR_STOP=1 -f 010_row_level_security.sql
psql -v ON_ERROR_STOP=1 -f 011_app_role.sql
psql -v ON_ERROR_STOP=1 -f 012_search_path.sql
```

| File | Contents |
|---|---|
| `000_complete_schema.sql` | extensions, 6 ENUM domains, 13 relations, indexes, triggers, functions, procedure, views |
| `007_dml.sql` | complete DML: INSERT/UPDATE/DELETE/SELECT, transactions, search, health checks H1–H5 |
| `008_verification.sql` | 17 negative tests + 4 positive tests |
| `009_search_and_staleness_fixes.sql` | per-serving search filters; staleness triggers on every embedded input |
| `010_row_level_security.sql` | RLS on all tables; read-only access to the published catalogue for the API roles |
| `011_app_role.sql` | read/write access for the application server login `app_dev`; audit and search logs append-only; no TRUNCATE |
| `012_search_path.sql` | `app_dev` can use the `extensions` schema (pgvector); vector functions pin their own search_path |

## Advanced features (brief requires 4; 7 present)

1. **Triggers** — `trg_recalc_nutrition`, `trg_guard_derived`, `trg_entry_window`, `trg_embedding_stale`, `trg_embedding_stale_ingredients`, `trg_embedding_stale_tags`
2. **Transactions** — meal-plan save, with ROLLBACK and SAVEPOINT cases
3. **Stored procedure** — `sp_generate_meal_plan`
4. **Views** — 5, using GROUP BY / HAVING / window functions
5. **Indexing** — B-tree, partial, expression, GIN, HNSW
6. **Vector similarity search** — cosine distance over pgvector
7. **Full-text search** — GIN + tsvector, retained as the comparison baseline

## Session variable

The application must set the acting user **inside** the transaction, or
audit rows are attributed to NULL:

```sql
BEGIN;
  SELECT set_config('app.user_id', '42', true);
  -- ... DML ...
COMMIT;
```

`true` means transaction-local. Under autocommit the setting is lost
before the trigger reads it.

## Verification

```bash
psql -v ON_ERROR_ROLLBACK=on -c 'BEGIN' -f 008_verification.sql -c 'ROLLBACK'
```

The outer transaction keeps the setup rows of the negative tests out of the
data. Expect ERROR lines for T1–T17 — that is the passing result. The
differential check (P3) must return **zero rows**.

## Tested against

PostgreSQL 17.6 + pgvector 0.8.2. All migrations apply cleanly; trigger
arithmetic, RESTRICT, enum rejection, window validation, derived-column
guard, embedding staleness, rollback, stored procedure and hybrid search
all verified.
