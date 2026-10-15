-- =====================================================================
-- 008_verification.sql
-- Negative tests: every statement here is EXPECTED TO FAIL.
--
-- A constraint that cannot be made to fire is not enforcing anything.
-- Run each block and confirm the stated SQLSTATE. Capture the output;
-- it is the evidence that integrity is enforced at database level
-- rather than only in application code.
--
-- Run with:  psql "$DATABASE_URL" -f 008_verification.sql
-- Expect a wall of ERROR lines. That is the passing result.
-- =====================================================================

\set ON_ERROR_STOP off

-- --------------------------------------------------------- UNIQUE -----
-- T1. Duplicate email.                       expect 23505 unique_violation
INSERT INTO users (full_name, email, password_hash)
VALUES ('Impostor', 'asha.raman@example.com', 'x');

-- T2. Same ingredient twice in one recipe.    expect 23505
INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g)
VALUES (1, 1, 100), (1, 1, 200);

-- T3. Two ratings by one user on one recipe.  expect 23505
INSERT INTO recipe_ratings (recipe_id, user_id, rating) VALUES (1, 1, 5);
INSERT INTO recipe_ratings (recipe_id, user_id, rating) VALUES (1, 1, 3);

-- T4. Double-booked meal slot.                expect 23505
INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
VALUES (1, 1, DATE '2026-10-20', 'snack');
INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
VALUES (1, 2, DATE '2026-10-20', 'snack');

-- T5. Second embedding for one recipe.        expect 23505
INSERT INTO recipe_embeddings
    (recipe_id, embedding_source_text, embedding, model_name, model_dim, content_hash)
VALUES (1, 'dup', array_fill(0.1, ARRAY[384])::vector, 'all-MiniLM-L6-v2', 384, repeat('a',64));


-- ---------------------------------------------------------- CHECK -----
-- T6. Negative quantity.                      expect 23514 check_violation
INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g)
VALUES (1, 2, -50);

-- T7. Rating outside 1..5.                    expect 23514
INSERT INTO recipe_ratings (recipe_id, user_id, rating) VALUES (2, 1, 6);

-- T8. Zero servings.                          expect 23514
INSERT INTO recipes (title, instructions, servings) VALUES ('Bad', 'x', 0);

-- T9. Plan ending before it starts.           expect 23514 chk_plan_window
INSERT INTO meal_plans (user_id, plan_name, start_date, end_date)
VALUES (1, 'Backwards', DATE '2026-10-10', DATE '2026-10-01');

-- T10. Wrong embedding dimensionality.        expect 23514 (model_dim = 384)
INSERT INTO recipe_embeddings
    (recipe_id, embedding_source_text, embedding, model_name, model_dim, content_hash)
VALUES (2, 'x', array_fill(0.1, ARRAY[384])::vector, 'other-model', 768, repeat('b',64));

-- T11. Uppercase email rejected by the case-fold CHECK. expect 23514
INSERT INTO users (full_name, email, password_hash)
VALUES ('Case', 'MixedCase@Example.com', 'x');


-- ----------------------------------------------------- FOREIGN KEY ----
-- T12. Composition row for a non-existent recipe. expect 23503 fk_violation
INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g)
VALUES (999999, 1, 100);

-- T13. RESTRICT: delete an ingredient still in use. expect 23503
DELETE FROM ingredients WHERE ingredient_id = 1;

-- T14. RESTRICT: delete a recipe scheduled in a plan. expect 23503
DELETE FROM recipes
 WHERE recipe_id IN (SELECT recipe_id FROM meal_plan_entries LIMIT 1);


-- ----------------------------------------------------------- ENUM -----
-- T15. Value outside the domain.              expect 22P02 invalid_text_representation
INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
VALUES (1, 1, DATE '2026-10-07', 'brunch');


-- -------------------------------------------------------- TRIGGERS ----
-- T16. Direct write to a derived column.      expect 23000, raised by
--      fn_guard_derived_nutrition. This is what makes the denormalisation
--      structural rather than a matter of discipline.
UPDATE recipes SET total_calories = 99999 WHERE recipe_id = 1;

-- T17. Entry outside its plan's date window.  expect 23514, raised by
--      fn_entry_within_plan_window (a cross-row rule a CHECK cannot express).
INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
VALUES (1, 1, DATE '2030-01-01', 'dinner');


-- =====================================================================
-- POSITIVE TESTS -- these must SUCCEED and produce the stated result.
-- =====================================================================
\set ON_ERROR_STOP on

-- P1. Trigger correctness under the full DML cycle.
BEGIN;
  SELECT set_config('app.user_id', '1', true);

  INSERT INTO recipes (title, instructions, servings, is_published)
  VALUES ('Trigger test', 'n/a', 1, FALSE) RETURNING recipe_id \gset

  -- 0 -> after insert
  INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g)
  VALUES (:recipe_id, (SELECT ingredient_id FROM ingredients WHERE name='chicken breast'), 100);
  SELECT 'after INSERT' AS step, total_calories, total_protein_g
    FROM recipes WHERE recipe_id = :recipe_id;      -- expect 165.00 / 31.00

  -- after update
  UPDATE recipe_ingredients SET quantity_g = 200
   WHERE recipe_id = :recipe_id;
  SELECT 'after UPDATE' AS step, total_calories, total_protein_g
    FROM recipes WHERE recipe_id = :recipe_id;      -- expect 330.00 / 62.00

  -- after delete
  DELETE FROM recipe_ingredients WHERE recipe_id = :recipe_id;
  SELECT 'after DELETE' AS step, total_calories, total_protein_g
    FROM recipes WHERE recipe_id = :recipe_id;      -- expect 0.00 / 0.00

  -- three audit rows, one per DML event
  SELECT COUNT(*) AS audit_rows FROM nutrition_audit_log
   WHERE recipe_id = :recipe_id;                    -- expect 3
ROLLBACK;

-- P2. Composition row moved between recipes: BOTH parents recomputed.
--     This is the edge case a naive COALESCE(NEW, OLD) trigger misses.
BEGIN;
  INSERT INTO recipes (title, instructions, servings) VALUES ('Src','x',1)
    RETURNING recipe_id AS src_id \gset
  INSERT INTO recipes (title, instructions, servings) VALUES ('Dst','x',1)
    RETURNING recipe_id AS dst_id \gset

  INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g)
  VALUES (:src_id, (SELECT ingredient_id FROM ingredients WHERE name='white rice'), 100);

  UPDATE recipe_ingredients SET recipe_id = :dst_id WHERE recipe_id = :src_id;

  SELECT 'source (must be 0)' AS which, total_calories FROM recipes WHERE recipe_id = :src_id;
  SELECT 'dest (must be 365)' AS which, total_calories FROM recipes WHERE recipe_id = :dst_id;
ROLLBACK;

-- P3. Differential check across the whole corpus. MUST return zero rows.
SELECT r.recipe_id, r.total_calories AS stored,
       ROUND(COALESCE(SUM(i.calories_per_100g * ri.quantity_g / 100.0), 0), 2) AS computed
  FROM recipes r
  LEFT JOIN recipe_ingredients ri ON ri.recipe_id = r.recipe_id
  LEFT JOIN ingredients i ON i.ingredient_id = ri.ingredient_id
 GROUP BY r.recipe_id, r.total_calories
HAVING r.total_calories
       <> ROUND(COALESCE(SUM(i.calories_per_100g * ri.quantity_g / 100.0), 0), 2);

-- P4. SQL injection attempt via a parameterised query. The payload is
--     treated as data; it matches nothing and drops no table.
PREPARE inj(TEXT) AS SELECT recipe_id, title FROM recipes WHERE title = $1;
EXECUTE inj('''; DROP TABLE recipes; --');
SELECT COUNT(*) AS recipes_still_present FROM recipes;
DEALLOCATE inj;
