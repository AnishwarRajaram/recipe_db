-- =====================================================================
-- 012_search_path.sql
-- pgvector and pgcrypto are installed in the "extensions" schema. A role
-- without USAGE on that schema, or without it on its search_path, cannot
-- resolve the vector type or the <=> operator.
-- 1. app_dev gets USAGE on extensions (Supabase grants it only to its own
--    roles) and public, extensions on its search_path (applied at
--    connection start, so reconnect after running this).
-- 2. Functions that use vectors pin their own search_path, so they work
--    for every caller regardless of the caller's settings.
-- Forward-only and safe to re-run.
-- =====================================================================

GRANT USAGE ON SCHEMA extensions TO app_dev;

ALTER ROLE app_dev SET search_path = public, extensions;

ALTER FUNCTION fn_search_recipes(vector, NUMERIC, NUMERIC, INT, VARCHAR,
                                 difficulty_level, INT[], INT[], INT)
    SET search_path = public, extensions;

ALTER FUNCTION sp_log_search(INT, TEXT, vector, JSONB, INT, INT)
    SET search_path = public, extensions;
