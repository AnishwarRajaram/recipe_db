-- =====================================================================
-- 007_dml.sql
-- Data Manipulation Language: the complete operation set.
--
-- Covers INSERT / UPDATE / DELETE / SELECT, and within SELECT: JOIN
-- (inner, left, self), GROUP BY, HAVING, ORDER BY, aggregate functions,
-- scalar and correlated subqueries, EXISTS / NOT EXISTS, IN, ANY,
-- set operations, CTEs, window functions, transactions with ROLLBACK
-- and SAVEPOINT, UPSERT, and vector similarity search.
--
-- Parameters are written as $1, $2 ... where the application would bind
-- them. Literal values are used where a statement is meant to be run
-- directly in psql.
-- =====================================================================


-- #####################################################################
-- SECTION A -- INSERT
-- #####################################################################

-- A1. Simple insert with RETURNING (how the API gets the new id back).
INSERT INTO users (full_name, email, password_hash, role)
VALUES ('Asha Rao', 'asha@example.com', '$argon2id$v=19$m=65536,t=3,p=4$...', 'registered_user')
RETURNING user_id, created_at;

-- A2. Multi-row insert.
--
-- IMPORTANT -- tag polarity. Allergen tags state what a recipe CONTAINS,
-- not what it is free of. This matters because the exclusion path works
-- by removing recipes that CARRY a listed tag:
--
--     NOT EXISTS (... rdt.tag_id = ANY(exclude_tags))
--
-- A tag named 'dairy_free' would invert that: excluding it would remove
-- exactly the safe recipes and keep the unsafe ones. Worse, an untagged
-- recipe would pass either way, so absence of a tag must mean "unknown",
-- never "safe". Stating allergens positively keeps the failure mode on
-- the safe side. Diet tags stay positive ('vegan' means it IS vegan) and
-- are used with require_tags rather than exclude_tags.
INSERT INTO dietary_tags (tag_name, tag_type, description) VALUES
    -- diet tags: assert what the recipe IS  -> use with p_require_tags
    ('vegan',             'diet',           'Contains no animal products'),
    ('vegetarian',        'diet',           'Contains no meat or fish'),
    ('gluten_free',       'diet',           'Contains no gluten-bearing grains'),
    -- allergen tags: assert what the recipe CONTAINS -> use with p_exclude_tags
    ('contains_dairy',    'allergen',       'Includes milk-derived ingredients'),
    ('contains_nuts',     'allergen',       'Includes tree nuts or peanuts'),
    ('contains_shellfish','allergen',       'Includes crustaceans or molluscs'),
    ('contains_egg',      'allergen',       'Includes egg'),
    ('contains_soy',      'allergen',       'Includes soy'),
    -- nutrition goals: derived, applied by A4 below
    ('high_protein',      'nutrition_goal', 'At least 25 g protein per serving'),
    ('low_carb',          'nutrition_goal', 'At most 20 g carbohydrate per serving');

-- A2b. Allergen tags derived from the composition rather than trusted.
-- Safer than manual tagging, because a human can forget and the
-- composition cannot. Run after every seed load.
INSERT INTO recipe_dietary_tags (recipe_id, tag_id)
SELECT DISTINCT ri.recipe_id,
       (SELECT tag_id FROM dietary_tags WHERE tag_name = 'contains_dairy')
  FROM recipe_ingredients ri
  JOIN ingredients i ON i.ingredient_id = ri.ingredient_id
 WHERE i.category = 'dairy_egg'
ON CONFLICT DO NOTHING;

INSERT INTO recipe_dietary_tags (recipe_id, tag_id)
SELECT DISTINCT ri.recipe_id,
       (SELECT tag_id FROM dietary_tags WHERE tag_name = 'contains_nuts')
  FROM recipe_ingredients ri
  JOIN ingredients i ON i.ingredient_id = ri.ingredient_id
 WHERE i.category = 'nut_seed' OR i.name = 'peanut butter'
ON CONFLICT DO NOTHING;

-- A3. UPSERT -- idempotent reference-data load. Re-running the seed
--     updates nutrition figures rather than failing on the UNIQUE(name).
INSERT INTO ingredients
    (name, category, calories_per_100g, protein_per_100g,
     carbs_per_100g, fat_per_100g, fiber_per_100g, sodium_mg_per_100g, source_ref)
VALUES
    ('chicken breast', 'poultry', 165, 31.0, 0.0, 3.6, 0.0, 74, 'USDA FDC 171477')
ON CONFLICT (name) DO UPDATE
    SET calories_per_100g  = EXCLUDED.calories_per_100g,
        protein_per_100g   = EXCLUDED.protein_per_100g,
        carbs_per_100g     = EXCLUDED.carbs_per_100g,
        fat_per_100g       = EXCLUDED.fat_per_100g,
        fiber_per_100g     = EXCLUDED.fiber_per_100g,
        sodium_mg_per_100g = EXCLUDED.sodium_mg_per_100g,
        source_ref         = EXCLUDED.source_ref;

-- A4. INSERT ... SELECT -- insert derived from a query rather than
--     from literals. Tags every recipe whose derived protein clears the
--     threshold, skipping any already tagged.
INSERT INTO recipe_dietary_tags (recipe_id, tag_id)
SELECT r.recipe_id,
       (SELECT tag_id FROM dietary_tags WHERE tag_name = 'high_protein')
  FROM recipes r
 WHERE r.total_protein_g / r.servings >= 25
ON CONFLICT (recipe_id, tag_id) DO NOTHING;

-- A5. Insert into the composition table. Note that no nutrition value
--     is supplied: trg_recalc_nutrition derives all four totals.
INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g, prep_note)
VALUES
    ($1, (SELECT ingredient_id FROM ingredients WHERE name = 'chicken breast'), 300, 'diced'),
    ($1, (SELECT ingredient_id FROM ingredients WHERE name = 'olive oil'),       15, NULL),
    ($1, (SELECT ingredient_id FROM ingredients WHERE name = 'garlic'),           9, 'minced');


-- #####################################################################
-- SECTION B -- UPDATE
-- #####################################################################

-- B1. Simple update.
UPDATE recipes
   SET is_published = TRUE
 WHERE recipe_id = $1
   AND author_id  = $2;          -- ownership enforced in SQL, not after fetch

-- B2. Update with a subquery in the SET clause.
UPDATE meal_plans
   SET target_daily_calories = (
         SELECT ROUND(AVG(r.total_calories / r.servings) * 3, 0)
           FROM recipes r
          WHERE r.is_published)
 WHERE plan_id = $1
   AND target_daily_calories IS NULL;

-- B3. Update from a join (UPDATE ... FROM).
UPDATE meal_plan_entries mpe
   SET servings = 2
  FROM meal_plans mp
 WHERE mpe.plan_id = mp.plan_id
   AND mp.user_id  = $1
   AND mp.status   = 'active';

-- B4. Update that fires the recalculation trigger.
UPDATE recipe_ingredients
   SET quantity_g = 450
 WHERE recipe_id = $1
   AND ingredient_id = (SELECT ingredient_id FROM ingredients WHERE name = 'chicken breast');

-- B5. Soft delete (the reason is_active exists).
UPDATE users SET is_active = FALSE WHERE user_id = $1;


-- #####################################################################
-- SECTION C -- DELETE
-- #####################################################################

-- C1. Delete a composition row; the trigger recomputes the parent.
DELETE FROM recipe_ingredients
 WHERE recipe_id = $1 AND ingredient_id = $2;

-- C2. Delete with a correlated subquery: remove draft plans that were
--     created but never populated.
DELETE FROM meal_plans mp
 WHERE mp.status = 'draft'
   AND mp.created_at < now() - INTERVAL '30 days'
   AND NOT EXISTS (SELECT 1 FROM meal_plan_entries e WHERE e.plan_id = mp.plan_id);

-- C3. Cascade demonstration: deleting a recipe removes its composition,
--     tags, ratings, embedding and audit rows, but is REFUSED if the
--     recipe is scheduled in any meal plan (ON DELETE RESTRICT).
DELETE FROM recipes WHERE recipe_id = $1;


-- #####################################################################
-- SECTION D -- SELECT: joins, grouping, subqueries
-- #####################################################################

-- D1. Inner join across four tables: full composition of one recipe with
--     each ingredient's contribution computed on the fly.
SELECT r.title,
       i.name                                           AS ingredient,
       ri.quantity_g,
       ri.prep_note,
       ROUND(i.calories_per_100g * ri.quantity_g / 100.0, 1) AS kcal_contributed,
       ROUND(i.protein_per_100g  * ri.quantity_g / 100.0, 1) AS protein_contributed
  FROM recipes r
  JOIN recipe_ingredients ri ON ri.recipe_id     = r.recipe_id
  JOIN ingredients i         ON i.ingredient_id  = ri.ingredient_id
 WHERE r.recipe_id = $1
 ORDER BY kcal_contributed DESC;

-- D2. LEFT JOIN: every recipe, including those with no ratings at all.
--     An inner join would silently drop unrated recipes.
SELECT r.recipe_id, r.title,
       COUNT(rr.rating_id)               AS review_count,
       COALESCE(ROUND(AVG(rr.rating), 2), 0) AS avg_rating
  FROM recipes r
  LEFT JOIN recipe_ratings rr ON rr.recipe_id = r.recipe_id
 WHERE r.is_published
 GROUP BY r.recipe_id, r.title
 ORDER BY avg_rating DESC NULLS LAST, review_count DESC;

-- D3. GROUP BY with HAVING and multiple aggregates.
SELECT r.cuisine,
       COUNT(*)                                   AS recipe_count,
       ROUND(AVG(r.total_calories / r.servings),1) AS avg_kcal_per_serving,
       MIN(r.total_calories / r.servings)          AS lightest,
       MAX(r.total_calories / r.servings)          AS heaviest
  FROM recipes r
 WHERE r.is_published AND r.cuisine IS NOT NULL
 GROUP BY r.cuisine
HAVING COUNT(*) >= 3
 ORDER BY avg_kcal_per_serving;

-- D4. Scalar subquery in the SELECT list.
SELECT r.title,
       r.total_calories,
       (SELECT COUNT(*) FROM recipe_ingredients ri WHERE ri.recipe_id = r.recipe_id)
           AS ingredient_count
  FROM recipes r
 WHERE r.is_published
 ORDER BY ingredient_count DESC
 LIMIT 10;

-- D5. Correlated subquery: recipes above the average calories for their
--     own cuisine.
SELECT r.title, r.cuisine, ROUND(r.total_calories / r.servings, 1) AS kcal
  FROM recipes r
 WHERE r.total_calories / r.servings > (
         SELECT AVG(r2.total_calories / r2.servings)
           FROM recipes r2
          WHERE r2.cuisine = r.cuisine AND r2.is_published)
   AND r.is_published
 ORDER BY r.cuisine, kcal DESC;

-- D6. NOT EXISTS: the dietary exclusion. This is the safety-critical
--     pattern -- an excluded recipe must be ABSENT, never merely ranked low.
SELECT r.recipe_id, r.title
  FROM recipes r
 WHERE r.is_published
   AND NOT EXISTS (
         SELECT 1
           FROM recipe_dietary_tags rdt
          WHERE rdt.recipe_id = r.recipe_id
            AND rdt.tag_id IN (SELECT tag_id FROM dietary_tags
                                WHERE tag_name IN ('contains_dairy')));

-- D7. Composition-derived exclusion -- stronger than trusting a tag,
--     because a tag can be missing or wrong. Rejects any recipe
--     containing an ingredient in a named category.
SELECT r.recipe_id, r.title
  FROM recipes r
 WHERE r.is_published
   AND NOT EXISTS (
         SELECT 1
           FROM recipe_ingredients ri
           JOIN ingredients i ON i.ingredient_id = ri.ingredient_id
          WHERE ri.recipe_id = r.recipe_id
            AND i.category = 'nut_seed');

-- D8. IN with a subquery: everything a specific user has rated highly.
SELECT r.title, rr.rating
  FROM recipes r
  JOIN recipe_ratings rr ON rr.recipe_id = r.recipe_id
 WHERE rr.user_id = $1
   AND r.recipe_id IN (SELECT recipe_id FROM recipe_ratings
                        WHERE user_id = $1 AND rating >= 4);

-- D9. Self-join: pairs of recipes sharing a cuisine, with similar
--     calorie counts. Ordering the ids prevents each pair appearing twice.
SELECT a.title AS recipe_a, b.title AS recipe_b, a.cuisine
  FROM recipes a
  JOIN recipes b
    ON a.cuisine = b.cuisine
   AND a.recipe_id < b.recipe_id
   AND abs(a.total_calories - b.total_calories) < 50
 WHERE a.is_published AND b.is_published;

-- D10. Set operations.
--      Ingredients used in Italian recipes but never in Indian ones.
SELECT i.name FROM ingredients i
  JOIN recipe_ingredients ri ON ri.ingredient_id = i.ingredient_id
  JOIN recipes r ON r.recipe_id = ri.recipe_id
 WHERE r.cuisine = 'Italian'
EXCEPT
SELECT i.name FROM ingredients i
  JOIN recipe_ingredients ri ON ri.ingredient_id = i.ingredient_id
  JOIN recipes r ON r.recipe_id = ri.recipe_id
 WHERE r.cuisine = 'Indian';

-- D11. CTE plus window function: rank recipes within each cuisine by
--      protein density, keeping only the top three per cuisine.
WITH ranked AS (
    SELECT r.recipe_id, r.title, r.cuisine,
           ROUND(r.total_protein_g / r.servings, 1) AS protein_per_serving,
           ROW_NUMBER() OVER (PARTITION BY r.cuisine
                              ORDER BY r.total_protein_g / r.servings DESC) AS rn
      FROM recipes r
     WHERE r.is_published AND r.cuisine IS NOT NULL
)
SELECT cuisine, title, protein_per_serving
  FROM ranked
 WHERE rn <= 3
 ORDER BY cuisine, rn;

-- D12. Recursive CTE: expand a plan's date range into one row per day,
--      including days with nothing scheduled (which a join alone misses).
WITH RECURSIVE days AS (
    SELECT start_date AS d, end_date FROM meal_plans WHERE plan_id = $1
    UNION ALL
    SELECT d + 1, end_date FROM days WHERE d < end_date
)
SELECT days.d AS plan_date,
       COUNT(mpe.entry_id) AS meals_scheduled
  FROM days
  LEFT JOIN meal_plan_entries mpe
         ON mpe.plan_id = $1 AND mpe.scheduled_date = days.d
 GROUP BY days.d
 ORDER BY days.d;


-- #####################################################################
-- SECTION E -- SEARCH: lexical and semantic
-- #####################################################################

-- E1. Lexical full-text search (the comparison baseline). Uses the GIN
--     index. Matches tokens, so an intent-phrased query returns little.
SELECT r.recipe_id, r.title,
       ts_rank(to_tsvector('english',
                 r.title || ' ' || COALESCE(r.description,'') || ' ' || COALESCE(r.cuisine,'')),
               plainto_tsquery('english', $1)) AS lexical_rank
  FROM recipes r
 WHERE to_tsvector('english',
         r.title || ' ' || COALESCE(r.description,'') || ' ' || COALESCE(r.cuisine,''))
       @@ plainto_tsquery('english', $1)
 ORDER BY lexical_rank DESC
 LIMIT 10;

-- E2. Pure vector similarity search. $1 is the query embedding.
SELECT r.recipe_id, r.title,
       ROUND((1 - (e.embedding <=> $1::vector))::NUMERIC, 4) AS similarity
  FROM recipe_embeddings e
  JOIN recipes r ON r.recipe_id = e.recipe_id
 ORDER BY e.embedding <=> $1::vector
 LIMIT 10;

-- E3. THE HYBRID QUERY -- the core of the project.
--     Structured predicates are CONSTRAINTS and sit in WHERE.
--     Semantic closeness is a PREFERENCE and sits in ORDER BY.
--     One statement, one planner, one transaction.
SELECT r.recipe_id,
       r.title,
       r.cuisine,
       ROUND(r.total_calories  / r.servings, 1) AS kcal_per_serving,
       ROUND(r.total_protein_g / r.servings, 1) AS protein_per_serving,
       COALESCE(r.prep_time_min,0) + COALESCE(r.cook_time_min,0) AS total_time_min,
       ROUND((1 - (e.embedding <=> $1::vector))::NUMERIC, 4) AS similarity
  FROM recipes r
  JOIN recipe_embeddings e ON e.recipe_id = r.recipe_id
 WHERE r.is_published
   AND r.total_protein_g / r.servings >= $2                         -- min protein
   AND (COALESCE(r.prep_time_min,0) + COALESCE(r.cook_time_min,0)) <= $3
   AND NOT EXISTS (                                                  -- hard exclusion
         SELECT 1 FROM recipe_dietary_tags rdt
          WHERE rdt.recipe_id = r.recipe_id
            AND rdt.tag_id = ANY($4::INT[]))
 ORDER BY e.embedding <=> $1::vector
 LIMIT $5;

-- E4. The same search, with the user's strict exclusions resolved from
--     their stored preferences rather than passed in.
SELECT r.recipe_id, r.title,
       ROUND((1 - (e.embedding <=> $1::vector))::NUMERIC, 4) AS similarity
  FROM recipes r
  JOIN recipe_embeddings e ON e.recipe_id = r.recipe_id
 WHERE r.is_published
   AND NOT EXISTS (
         SELECT 1
           FROM recipe_dietary_tags rdt
           JOIN user_dietary_preferences udp
             ON udp.tag_id = rdt.tag_id
          WHERE rdt.recipe_id = r.recipe_id
            AND udp.user_id   = $2
            AND udp.strictness = 'strict')
 ORDER BY e.embedding <=> $1::vector
 LIMIT 10;

-- E5. Via the stored function (identical semantics, logic held in one place).
SELECT * FROM fn_search_recipes(
    p_query_embedding := $1::vector,
    p_min_protein     := 25,
    p_max_total_time  := 30,
    p_exclude_tags    := fn_strict_exclusions($2),
    p_limit           := 10);

-- E6. Log the search (append-only).
SELECT sp_log_search($1, $2, $3::vector, $4::jsonb, $5, $6);


-- #####################################################################
-- SECTION F -- TRANSACTIONS
-- #####################################################################

-- F1. Atomic meal-plan creation. Either the header and every entry
--     persist, or none do.
BEGIN;
    SELECT set_config('app.user_id', '1', true);   -- attribute audit rows

    INSERT INTO meal_plans (user_id, plan_name, start_date, end_date, status)
    VALUES (1, 'Week of 6 October', DATE '2026-10-06', DATE '2026-10-12', 'draft')
    RETURNING plan_id \gset

    INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot, servings)
    VALUES (:plan_id, 1, DATE '2026-10-06', 'breakfast', 1),
           (:plan_id, 2, DATE '2026-10-06', 'lunch',     1),
           (:plan_id, 3, DATE '2026-10-06', 'dinner',    2);

    UPDATE meal_plans SET status = 'active' WHERE plan_id = :plan_id;
COMMIT;

-- F2. Deliberate rollback -- the atomicity test. The second entry
--     violates UNIQUE (plan_id, scheduled_date, meal_slot); nothing
--     from this transaction survives.
BEGIN;
    INSERT INTO meal_plans (user_id, plan_name, start_date, end_date)
    VALUES (1, 'Doomed plan', DATE '2026-10-06', DATE '2026-10-08')
    RETURNING plan_id \gset

    INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
    VALUES (:plan_id, 1, DATE '2026-10-06', 'lunch');
    INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
    VALUES (:plan_id, 2, DATE '2026-10-06', 'lunch');   -- duplicate slot
ROLLBACK;

-- Verify nothing persisted:
SELECT COUNT(*) AS should_be_zero FROM meal_plans WHERE plan_name = 'Doomed plan';

-- F3. SAVEPOINT: partial rollback inside a larger unit of work.
BEGIN;
    INSERT INTO recipe_ratings (recipe_id, user_id, rating, review_text)
    VALUES (1, 1, 5, 'Excellent');

    SAVEPOINT before_risky;
    INSERT INTO recipe_ratings (recipe_id, user_id, rating, review_text)
    VALUES (1, 1, 4, 'Duplicate -- violates UNIQUE');   -- fails
    ROLLBACK TO SAVEPOINT before_risky;

    -- The first rating is still pending and will commit.
COMMIT;

-- F4. Calling the stored procedure. It manages its own consistency;
--     an exception inside it aborts the whole call.
CALL sp_generate_meal_plan(
    p_user_id     := 1,
    p_plan_name   := 'Generated week',
    p_start_date  := DATE '2026-10-13',
    p_end_date    := DATE '2026-10-17',
    p_target_kcal := 2100,
    p_plan_id     := NULL);

-- F5. Explicit row locking, for the read-modify-write case.
BEGIN;
    SELECT status FROM meal_plans WHERE plan_id = $1 FOR UPDATE;
    UPDATE meal_plans SET status = 'completed' WHERE plan_id = $1;
COMMIT;


-- #####################################################################
-- SECTION G -- READING THE VIEWS
-- #####################################################################

SELECT * FROM v_recipe_nutrition_per_serving
 WHERE kcal_per_serving < 600 AND protein_g_per_serving >= 25
 ORDER BY protein_g_per_serving DESC;

SELECT * FROM v_recipe_rating_summary ORDER BY avg_rating DESC LIMIT 10;

SELECT * FROM v_meal_plan_daily_rollup
 WHERE plan_id = $1 ORDER BY scheduled_date;

SELECT * FROM v_ingredient_usage
 WHERE deletion_blocked ORDER BY usage_rank LIMIT 15;

SELECT * FROM v_search_analytics LIMIT 14;


-- #####################################################################
-- SECTION H -- AUDIT AND VERIFICATION QUERIES
-- #####################################################################

-- H1. The trigger's paper trail for one recipe.
SELECT nal.log_id, nal.changed_at, u.full_name AS changed_by,
       nal.old_total_calories, nal.new_total_calories,
       ROUND(nal.new_total_calories - COALESCE(nal.old_total_calories, 0), 2) AS delta,
       nal.change_reason
  FROM nutrition_audit_log nal
  LEFT JOIN users u ON u.user_id = nal.changed_by
 WHERE nal.recipe_id = $1
 ORDER BY nal.changed_at DESC;

-- H2. Differential test. Compares each stored aggregate against a freshly
--     computed one. MUST return zero rows; any row is a trigger defect.
SELECT r.recipe_id, r.title,
       r.total_calories AS stored_kcal,
       ROUND(COALESCE(SUM(i.calories_per_100g * ri.quantity_g / 100.0), 0), 2) AS computed_kcal
  FROM recipes r
  LEFT JOIN recipe_ingredients ri ON ri.recipe_id    = r.recipe_id
  LEFT JOIN ingredients i         ON i.ingredient_id = ri.ingredient_id
 GROUP BY r.recipe_id, r.title, r.total_calories,
          r.total_protein_g, r.total_carbs_g, r.total_fat_g
HAVING r.total_calories
       <> ROUND(COALESCE(SUM(i.calories_per_100g * ri.quantity_g / 100.0), 0), 2);

-- H3. Embedding coverage: published recipes with no vector, which would
--     be invisible to semantic search.
SELECT r.recipe_id, r.title
  FROM recipes r
  LEFT JOIN recipe_embeddings e ON e.recipe_id = r.recipe_id
 WHERE r.is_published AND e.embedding_id IS NULL;

-- H4. Stale embeddings flagged by trg_embedding_stale.
SELECT r.recipe_id, r.title, e.generated_at
  FROM recipe_embeddings e
  JOIN recipes r ON r.recipe_id = e.recipe_id
 WHERE e.content_hash = repeat('0', 64);

-- H5. Confirm the vector index is actually being used. Look for
--     "Index Scan using idx_emb_hnsw", not "Seq Scan".
EXPLAIN ANALYZE
SELECT r.recipe_id
  FROM recipes r
  JOIN recipe_embeddings e ON e.recipe_id = r.recipe_id
 ORDER BY e.embedding <=> (SELECT embedding FROM recipe_embeddings LIMIT 1)
 LIMIT 10;
