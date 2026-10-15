-- =====================================================================
-- 009_search_and_staleness_fixes.sql
-- 1. fn_search_recipes: protein and calorie limits apply per serving,
--    consistent with the nutrition-goal tags, sp_generate_meal_plan and
--    v_recipe_nutrition_per_serving.
-- 2. Embedding staleness: every input to fn_recipe_embedding_source now
--    marks the stored vector stale (title, description, cuisine, total
--    time, difficulty, tags, ingredients).
-- Forward-only and safe to re-run.
-- =====================================================================

CREATE OR REPLACE FUNCTION fn_search_recipes(
    p_query_embedding vector(384),
    p_min_protein     NUMERIC      DEFAULT NULL,
    p_max_calories    NUMERIC      DEFAULT NULL,
    p_max_total_time  INT          DEFAULT NULL,
    p_cuisine         VARCHAR      DEFAULT NULL,
    p_difficulty      difficulty_level DEFAULT NULL,
    p_exclude_tags    INT[]        DEFAULT '{}',
    p_require_tags    INT[]        DEFAULT '{}',
    p_limit           INT          DEFAULT 10
)
RETURNS TABLE (
    recipe_id       INT,
    title           VARCHAR(200),
    cuisine         VARCHAR(60),
    total_calories  NUMERIC(8,2),
    total_protein_g NUMERIC(7,2),
    total_time_min  INT,
    similarity      NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT r.recipe_id,
           r.title,
           r.cuisine,
           r.total_calories,
           r.total_protein_g,
           (COALESCE(r.prep_time_min,0) + COALESCE(r.cook_time_min,0))::INT,
           ROUND((1 - (e.embedding <=> p_query_embedding))::NUMERIC, 4)
      FROM recipes r
      JOIN recipe_embeddings e ON e.recipe_id = r.recipe_id
     WHERE r.is_published

       AND (p_min_protein    IS NULL OR r.total_protein_g / r.servings >= p_min_protein)
       AND (p_max_calories   IS NULL OR r.total_calories  / r.servings <= p_max_calories)
       AND (p_max_total_time IS NULL OR
            (COALESCE(r.prep_time_min,0) + COALESCE(r.cook_time_min,0)) <= p_max_total_time)
       AND (p_cuisine        IS NULL OR r.cuisine    = p_cuisine)
       AND (p_difficulty     IS NULL OR r.difficulty = p_difficulty)

       AND NOT EXISTS (
             SELECT 1 FROM recipe_dietary_tags x
              WHERE x.recipe_id = r.recipe_id
                AND x.tag_id = ANY(p_exclude_tags))

       AND (cardinality(p_require_tags) = 0 OR NOT EXISTS (
             SELECT 1 FROM unnest(p_require_tags) AS want(tag_id)
              WHERE NOT EXISTS (
                    SELECT 1 FROM recipe_dietary_tags h
                     WHERE h.recipe_id = r.recipe_id
                       AND h.tag_id = want.tag_id)))

     ORDER BY e.embedding <=> p_query_embedding
     LIMIT p_limit;
$$;

-- Recipe columns that feed the embedded projection.
CREATE OR REPLACE FUNCTION fn_mark_embedding_stale()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.title         IS DISTINCT FROM OLD.title
    OR NEW.description   IS DISTINCT FROM OLD.description
    OR NEW.cuisine       IS DISTINCT FROM OLD.cuisine
    OR NEW.prep_time_min IS DISTINCT FROM OLD.prep_time_min
    OR NEW.cook_time_min IS DISTINCT FROM OLD.cook_time_min
    OR NEW.difficulty    IS DISTINCT FROM OLD.difficulty THEN
        UPDATE recipe_embeddings
           SET content_hash = repeat('0', 64)
         WHERE recipe_id = NEW.recipe_id;
    END IF;
    RETURN NEW;
END; $$;

-- Child rows (ingredients, tags) that feed the embedded projection.
-- An UPDATE that moves a row between recipes marks both recipes.
CREATE OR REPLACE FUNCTION fn_mark_embedding_stale_child()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE recipe_embeddings
       SET content_hash = repeat('0', 64)
     WHERE recipe_id IN (
           CASE WHEN TG_OP <> 'INSERT' THEN OLD.recipe_id END,
           CASE WHEN TG_OP <> 'DELETE' THEN NEW.recipe_id END);
    RETURN NULL;
END; $$;

DROP TRIGGER IF EXISTS trg_embedding_stale_ingredients ON recipe_ingredients;
CREATE TRIGGER trg_embedding_stale_ingredients
    AFTER INSERT OR UPDATE OR DELETE ON recipe_ingredients
    FOR EACH ROW EXECUTE FUNCTION fn_mark_embedding_stale_child();

DROP TRIGGER IF EXISTS trg_embedding_stale_tags ON recipe_dietary_tags;
CREATE TRIGGER trg_embedding_stale_tags
    AFTER INSERT OR UPDATE OR DELETE ON recipe_dietary_tags
    FOR EACH ROW EXECUTE FUNCTION fn_mark_embedding_stale_child();
