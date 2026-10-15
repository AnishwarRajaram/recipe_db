# Semantic Recipe Discovery and Nutrition Planning Database

A PostgreSQL database that combines two paradigms in one instance:

- **Relational** (PostgreSQL): a normalised schema for users, recipes, ingredients,
  dietary tags, ratings and meal plans, with integrity enforced in DDL.
- **Vector** (pgvector): one 384-dimension embedding per recipe, searched by cosine
  distance over an HNSW index.

A single hybrid query applies hard constraints (protein, time, allergens) as SQL
predicates and ranks the surviving recipes by semantic similarity to a
natural-language request.

## Database features

| Feature | Where |
|---|---|
| Triggers (6) | `trg_recalc_nutrition` keeps recipe nutrition totals in sync with the ingredient list and writes `nutrition_audit_log`; `trg_guard_derived` blocks direct writes to those totals; `trg_entry_window` keeps meal-plan entries inside the plan dates; `trg_embedding_stale`, `trg_embedding_stale_ingredients`, `trg_embedding_stale_tags` flag embeddings whose source text changed |
| Stored procedure | `sp_generate_meal_plan` builds a plan under a calorie target, honouring strict dietary exclusions |
| Transactions | one transaction per recipe load and per meal plan; attribution through `set_config('app.user_id', ..., true)` |
| Views (5) | `v_recipe_nutrition_per_serving`, `v_recipe_rating_summary`, `v_meal_plan_daily_rollup`, `v_ingredient_usage`, `v_search_analytics` |
| Indexes | HNSW (vector), GIN (full-text), B-tree and composite |
| Vector search | `fn_search_recipes` (hybrid filter + cosine ranking), `fn_strict_exclusions` |
| Full-text search | GIN-indexed `tsvector`, kept as the keyword baseline for comparison |

## Repository layout

```
SQL/000_complete_schema.sql           full schema: types, tables, indexes, triggers, functions, views
SQL/007_dml.sql                       DML examples and health checks H1 to H5
SQL/008_verification.sql              17 negative tests (must fail) and 4 positive tests
SQL/009_search_and_staleness_fixes.sql per-serving search filters, extended staleness triggers
scripts/build_ingredients.py          USDA SR Legacy CSVs -> seed/ingredients.json
scripts/load_reference.py             reset, dietary tags, ingredients, users, preferences
scripts/load_recipes.py               validated recipe load and derived tags
scripts/load_activity.py              ratings and meal plans
scripts/embed_recipes.py              idempotent embedding ingestion
scripts/compare_retrieval.py          keyword vs vector precision at 5
scripts/log_query.py                  embeds a text query and stores it in search_queries
seed/                                 ingredient, recipe and relevance-judgment data
results/                              verification output and retrieval comparison
```

## Requirements

- PostgreSQL 16 or later with the `vector` and `pgcrypto` extensions (tested on PostgreSQL 17, pgvector 0.8)
- Python 3.12
- `psql` on the PATH

## Setup

```bash
python3.12 -m venv venv
venv/bin/pip install -r requirements.txt

cp db.env.example db.env      # fill in the connection values; db.env is git-ignored
set -a; source db.env; set +a
```

All scripts read the standard `PG*` environment variables. No connection details are
stored in the repository.

### 1. Create the schema

```bash
psql -v ON_ERROR_STOP=1 -f SQL/000_complete_schema.sql
psql -v ON_ERROR_STOP=1 -f SQL/009_search_and_staleness_fixes.sql
```

Both files are safe to re-run.

### 2. Nutrition reference data

Ingredient nutrition comes from the USDA FoodData Central **SR Legacy** dataset (CSV
download from fdc.nal.usda.gov). Place `food.csv`, `food_nutrient.csv` and
`nutrient.csv` in `data/usda/`, then:

```bash
venv/bin/python scripts/build_ingredients.py
```

Every ingredient row records its FDC ID in `source_ref`. `seed/ingredients.json` is
committed, so this step is only needed to rebuild it.

### 3. Populate

Run in this order:

```bash
venv/bin/python scripts/load_reference.py                       # resets all tables, then tags, ingredients, users
venv/bin/python scripts/load_recipes.py seed/recipes.json       # validates every ingredient name first
venv/bin/python scripts/load_recipes.py seed/recipes_extra.json
psql -v ON_ERROR_STOP=1 -f seed/title_renames.sql
venv/bin/python scripts/load_activity.py                        # ratings and meal plans
venv/bin/python scripts/embed_recipes.py                        # downloads all-MiniLM-L6-v2 on first run
```

Rules the loaders follow:

- Recipe nutrition totals are never written directly. They are derived by the trigger
  from `recipe_ingredients`.
- Allergen tags (`contains_*`) are derived from the ingredient list, and nutrition-goal
  tags (`high_protein`, `low_carb`, `low_calorie`, `high_fibre`) from per-serving totals.
- `load_recipes.py` stops if any ingredient name is not in the `ingredients` table.
- Password hashes are bcrypt digests produced by `pgcrypto` from random throwaway passwords.
- The embedded text comes only from `fn_recipe_embedding_source(recipe_id)`. Method text
  is excluded.

## Verification

```bash
# Health checks H2 to H4 must return zero rows; H5 must show "Index Scan using idx_emb_hnsw"
psql -f SQL/007_dml.sql          # or run the H-section queries individually

# Negative and positive tests, inside a transaction that is rolled back
psql -v ON_ERROR_ROLLBACK=on -c 'BEGIN' -f SQL/008_verification.sql -c 'ROLLBACK'

# Embedding idempotence: the second run must report "to embed: 0"
venv/bin/python scripts/embed_recipes.py
```

008 is wrapped in a rolled-back transaction because some tests insert a valid row
before the failing one. The expected result is 17 `ERROR` lines, P2 showing `0.00`
and `365.00`, an empty P3, and P4 reporting all recipes still present. A captured run
is in `results/008_output.txt`.

## Querying

Plain SQL cannot turn text into a vector, so a text query is embedded once with the
same model used for the recipes and stored in `search_queries`:

```bash
venv/bin/python scripts/log_query.py "something warming for a cold evening"
```

The stored vector can then be used from SQL:

```sql
-- Semantic search on the most recent logged query
SELECT * FROM fn_search_recipes(
  (SELECT query_embedding FROM search_queries ORDER BY query_id DESC LIMIT 1), p_limit := 5);

-- Hybrid: at most 30 minutes, at least 25 g protein per serving, no dairy
SELECT * FROM fn_search_recipes(
  (SELECT query_embedding FROM search_queries ORDER BY query_id DESC LIMIT 1),
  p_min_protein := 25, p_max_total_time := 30,
  p_exclude_tags := ARRAY(SELECT tag_id FROM dietary_tags WHERE tag_name = 'contains_dairy'));

-- Strict exclusions for a user: no recipe carrying an excluded tag can appear
SELECT * FROM fn_search_recipes(
  (SELECT embedding FROM recipe_embeddings WHERE recipe_id = 2),
  p_exclude_tags := fn_strict_exclusions((SELECT user_id FROM users WHERE email = 'priya.nair@example.com')),
  p_limit := 10);

-- Raw pgvector: cosine distance over the HNSW index
SELECT r.recipe_id, r.title, 1 - (e.embedding <=> q.v) AS similarity
FROM recipe_embeddings e JOIN recipes r USING (recipe_id),
     (SELECT query_embedding AS v FROM search_queries ORDER BY query_id DESC LIMIT 1) q
ORDER BY e.embedding <=> q.v LIMIT 5;

-- "More like this"
SELECT * FROM fn_search_recipes((SELECT embedding FROM recipe_embeddings WHERE recipe_id = 27), p_limit := 6);

-- Keyword baseline on the same intent (any word, ranked)
WITH q AS (SELECT replace(plainto_tsquery('english', 'warming cold evening')::text, '&', '|')::tsquery AS tq)
SELECT r.recipe_id, r.title FROM recipes r, q
WHERE to_tsvector('english', r.title || ' ' || coalesce(r.description, '') || ' ' || coalesce(r.cuisine, '')) @@ q.tq
ORDER BY ts_rank(to_tsvector('english', r.title || ' ' || coalesce(r.description, '') || ' ' || coalesce(r.cuisine, '')), q.tq) DESC
LIMIT 5;

-- Per-serving nutrition, rating summary, meal-plan rollup
SELECT * FROM v_recipe_nutrition_per_serving LIMIT 10;
SELECT * FROM v_recipe_rating_summary ORDER BY avg_rating DESC LIMIT 10;
SELECT * FROM v_meal_plan_daily_rollup ORDER BY plan_id, scheduled_date;

-- Generate a meal plan with the stored procedure
CALL sp_generate_meal_plan(p_user_id := 1, p_plan_name := 'Test week',
  p_start_date := DATE '2026-10-19', p_end_date := DATE '2026-10-23',
  p_target_kcal := 2100, p_plan_id := NULL);
```

## Dataset

- **Recipes:** a synthetic corpus generated with a large language model
  (`seed/recipe_prompt.md`), restricted to a fixed ingredient vocabulary and validated
  by `load_recipes.py` before loading. The generator supplies names, grams and
  descriptions only; it produces no nutrition values.
- **Nutrition:** USDA FoodData Central SR Legacy (public domain). Each ingredient
  records its FDC ID in `source_ref`, and every recipe total is computed by the
  database from those figures.

| Table | Rows |
|---|---|
| ingredients | 105 (nutrition per 100 g from USDA SR Legacy) |
| recipes | 151 across 22 cuisines |
| recipe_ingredients | 1,056 |
| dietary_tags | 13 (diet, allergen, nutrition goal) |
| users | 10 (2 admins); 7 dietary preferences |
| recipe_ratings | 217 |
| meal_plans / entries | 4 / 54 |
| recipe_embeddings | 151 (all-MiniLM-L6-v2, 384 dimensions) |

## Retrieval comparison

Ten intent-phrased queries were run with keyword full-text search and with vector
search on the same corpus. Precision at 5 is scored against the judgments in
`seed/relevance_judgments.json`:

| | Keyword | Vector |
|---|---|---|
| Mean precision at 5 | 0.30 | 0.52 |

Per-query results are in `results/retrieval_comparison.csv`. Rerun with:

```bash
venv/bin/python scripts/compare_retrieval.py score
```
