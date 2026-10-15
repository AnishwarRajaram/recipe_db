-- =====================================================================
-- 010_row_level_security.sql
-- Row-level security for the hosted API roles (anon, authenticated).
-- RLS is enabled on every table; without a policy a role sees nothing.
-- Read-only policies expose the published recipe catalogue only. Users,
-- preferences, meal plans, ratings, search logs and the audit log stay
-- private. Table owners bypass RLS, so migrations and loaders are unaffected.
-- Views are switched to security_invoker so they respect the policies.
-- Forward-only and safe to re-run.
-- =====================================================================

DO $$
DECLARE t TEXT;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    END LOOP;
END $$;

DROP POLICY IF EXISTS read_published ON recipes;
CREATE POLICY read_published ON recipes
    FOR SELECT TO anon, authenticated USING (is_published);

DROP POLICY IF EXISTS read_all ON ingredients;
CREATE POLICY read_all ON ingredients
    FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS read_all ON dietary_tags;
CREATE POLICY read_all ON dietary_tags
    FOR SELECT TO anon, authenticated USING (true);

-- Child rows are visible only for published recipes.
DROP POLICY IF EXISTS read_published ON recipe_ingredients;
CREATE POLICY read_published ON recipe_ingredients
    FOR SELECT TO anon, authenticated
    USING (EXISTS (SELECT 1 FROM recipes r WHERE r.recipe_id = recipe_ingredients.recipe_id AND r.is_published));

DROP POLICY IF EXISTS read_published ON recipe_dietary_tags;
CREATE POLICY read_published ON recipe_dietary_tags
    FOR SELECT TO anon, authenticated
    USING (EXISTS (SELECT 1 FROM recipes r WHERE r.recipe_id = recipe_dietary_tags.recipe_id AND r.is_published));

DROP POLICY IF EXISTS read_published ON recipe_embeddings;
CREATE POLICY read_published ON recipe_embeddings
    FOR SELECT TO anon, authenticated
    USING (EXISTS (SELECT 1 FROM recipes r WHERE r.recipe_id = recipe_embeddings.recipe_id AND r.is_published));

ALTER VIEW v_recipe_nutrition_per_serving SET (security_invoker = true);
ALTER VIEW v_recipe_rating_summary        SET (security_invoker = true);
ALTER VIEW v_meal_plan_daily_rollup       SET (security_invoker = true);
ALTER VIEW v_ingredient_usage             SET (security_invoker = true);
ALTER VIEW v_search_analytics             SET (security_invoker = true);

-- Strict dietary exclusions depend on a verified user, so they are resolved
-- server-side only. Without EXECUTE an API-role call fails with an error
-- instead of silently returning an empty exclusion list.
REVOKE EXECUTE ON FUNCTION fn_strict_exclusions(INT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON PROCEDURE sp_generate_meal_plan(INT, VARCHAR, DATE, DATE, NUMERIC, INT)
    FROM PUBLIC, anon, authenticated;
