-- =====================================================================
-- 011_app_role.sql
-- Access for app_dev, the login used by the application server.
-- The server enforces user roles and ownership itself, so app_dev may
-- read and write the application tables. The audit log and search log
-- are append-only for it, and TRUNCATE is never granted. Nutrition totals
-- stay protected by trg_guard_derived regardless of role.
-- Forward-only and safe to re-run.
-- =====================================================================

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM app_dev;

GRANT SELECT, INSERT, UPDATE, DELETE ON
    users, user_dietary_preferences, ingredients, dietary_tags,
    recipes, recipe_ingredients, recipe_dietary_tags, recipe_ratings,
    meal_plans, meal_plan_entries, recipe_embeddings
TO app_dev;

GRANT SELECT, INSERT ON nutrition_audit_log, search_queries TO app_dev;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_dev;

GRANT EXECUTE ON FUNCTION fn_strict_exclusions(INT) TO app_dev;
GRANT EXECUTE ON PROCEDURE sp_generate_meal_plan(INT, VARCHAR, DATE, DATE, NUMERIC, INT) TO app_dev;

-- Row-level security: app_dev sees and changes every row; the grants above
-- decide which operations are allowed on each table.
DO $$
DECLARE t TEXT;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
        EXECUTE format('DROP POLICY IF EXISTS app_all ON public.%I', t);
        EXECUTE format('CREATE POLICY app_all ON public.%I FOR ALL TO app_dev '
                       'USING (true) WITH CHECK (true)', t);
    END LOOP;
END $$;
