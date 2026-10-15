CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

DO $$ BEGIN
    CREATE TYPE user_role AS ENUM ('admin', 'registered_user');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN

    CREATE TYPE pref_strictness AS ENUM ('strict', 'preferred', 'avoid');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE tag_kind AS ENUM ('diet', 'allergen', 'nutrition_goal');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE difficulty_level AS ENUM ('easy', 'medium', 'hard');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE plan_status AS ENUM ('draft', 'active', 'completed', 'archived');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE meal_slot_type AS ENUM ('breakfast', 'lunch', 'dinner', 'snack');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

CREATE TABLE IF NOT EXISTS users (
    user_id       SERIAL PRIMARY KEY,
    full_name     VARCHAR(120) NOT NULL CHECK (length(trim(full_name)) > 0),
    email         VARCHAR(180) NOT NULL UNIQUE
                      CHECK (email = lower(email) AND position('@' IN email) > 1),
    password_hash TEXT         NOT NULL,
    role          user_role    NOT NULL DEFAULT 'registered_user',
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON COLUMN users.email IS
    'Stored case-folded; the CHECK enforces it so two accounts cannot '
    'differ only by letter case.';
COMMENT ON COLUMN users.is_active IS
    'Soft-disable. Deactivating rather than deleting preserves referential '
    'integrity for authored recipes and historical ratings.';

CREATE TABLE IF NOT EXISTS dietary_tags (
    tag_id      SERIAL PRIMARY KEY,
    tag_name    VARCHAR(60) NOT NULL UNIQUE
                    CHECK (tag_name = lower(tag_name)),
    tag_type    tag_kind    NOT NULL,
    description TEXT
);

COMMENT ON TABLE dietary_tags IS
    'Declarable labels only. Numeric constraints (calorie ceilings, protein '
    'floors) are predicates on recipes.total_*; composition-derived exclusions '
    'are NOT EXISTS subqueries over recipe_ingredients. Tags are one of three '
    'constraint mechanisms, not all of them.';

CREATE TABLE IF NOT EXISTS user_dietary_preferences (
    user_id    INT             NOT NULL
                   REFERENCES users(user_id) ON DELETE CASCADE,
    tag_id     INT             NOT NULL
                   REFERENCES dietary_tags(tag_id) ON DELETE CASCADE,
    strictness pref_strictness NOT NULL DEFAULT 'preferred',
    PRIMARY KEY (user_id, tag_id)
);

CREATE TABLE IF NOT EXISTS ingredients (
    ingredient_id      SERIAL PRIMARY KEY,
    name               VARCHAR(120) NOT NULL UNIQUE
                           CHECK (name = lower(name)),
    category           VARCHAR(60),
    calories_per_100g  NUMERIC(7,2) NOT NULL CHECK (calories_per_100g  >= 0),
    protein_per_100g   NUMERIC(6,2) NOT NULL CHECK (protein_per_100g   >= 0),
    carbs_per_100g     NUMERIC(6,2) NOT NULL CHECK (carbs_per_100g     >= 0),
    fat_per_100g       NUMERIC(6,2) NOT NULL CHECK (fat_per_100g       >= 0),
    fiber_per_100g     NUMERIC(6,2)          CHECK (fiber_per_100g     >= 0),
    sodium_mg_per_100g NUMERIC(7,2)          CHECK (sodium_mg_per_100g >= 0),
    source_ref         VARCHAR(80)
);

COMMENT ON COLUMN ingredients.source_ref IS
    'Provenance of the nutrition figures, e.g. a USDA FoodData Central FDC ID. '
    'Recorded so derived recipe totals are traceable to an authority rather '
    'than to invented numbers.';

CREATE TABLE IF NOT EXISTS recipes (
    recipe_id       SERIAL PRIMARY KEY,
    title           VARCHAR(200)     NOT NULL CHECK (length(trim(title)) > 0),
    description     TEXT,
    instructions    TEXT             NOT NULL,
    cuisine         VARCHAR(60),
    difficulty      difficulty_level,
    prep_time_min   SMALLINT         CHECK (prep_time_min >= 0),
    cook_time_min   SMALLINT         CHECK (cook_time_min >= 0),
    servings        SMALLINT         NOT NULL CHECK (servings > 0),
    author_id       INT              REFERENCES users(user_id) ON DELETE SET NULL,

    total_calories  NUMERIC(8,2)     NOT NULL DEFAULT 0 CHECK (total_calories  >= 0),
    total_protein_g NUMERIC(7,2)     NOT NULL DEFAULT 0 CHECK (total_protein_g >= 0),
    total_carbs_g   NUMERIC(7,2)     NOT NULL DEFAULT 0 CHECK (total_carbs_g   >= 0),
    total_fat_g     NUMERIC(7,2)     NOT NULL DEFAULT 0 CHECK (total_fat_g     >= 0),

    is_published    BOOLEAN          NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ      NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ      NOT NULL DEFAULT now()
);

COMMENT ON COLUMN recipes.total_calories IS
    'DERIVED. Never written by application code. Maintained by '
    'trg_recalc_nutrition within the same transaction as the DML that '
    'changed recipe_ingredients.';

CREATE TABLE IF NOT EXISTS recipe_ingredients (
    recipe_ingredient_id SERIAL PRIMARY KEY,
    recipe_id            INT          NOT NULL
                             REFERENCES recipes(recipe_id) ON DELETE CASCADE,
    ingredient_id        INT          NOT NULL
                             REFERENCES ingredients(ingredient_id) ON DELETE RESTRICT,
    quantity_g           NUMERIC(8,2) NOT NULL CHECK (quantity_g > 0),
    prep_note            VARCHAR(120),
    UNIQUE (recipe_id, ingredient_id)
);

CREATE TABLE IF NOT EXISTS recipe_dietary_tags (
    recipe_id INT NOT NULL REFERENCES recipes(recipe_id)      ON DELETE CASCADE,
    tag_id    INT NOT NULL REFERENCES dietary_tags(tag_id)    ON DELETE CASCADE,
    PRIMARY KEY (recipe_id, tag_id)
);

CREATE TABLE IF NOT EXISTS recipe_ratings (
    rating_id   SERIAL PRIMARY KEY,
    recipe_id   INT         NOT NULL REFERENCES recipes(recipe_id) ON DELETE CASCADE,
    user_id     INT         NOT NULL REFERENCES users(user_id)     ON DELETE CASCADE,
    rating      SMALLINT    NOT NULL CHECK (rating BETWEEN 1 AND 5),
    review_text TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (recipe_id, user_id)
);

CREATE TABLE IF NOT EXISTS meal_plans (
    plan_id               SERIAL PRIMARY KEY,
    user_id               INT          NOT NULL
                              REFERENCES users(user_id) ON DELETE CASCADE,
    plan_name             VARCHAR(140) NOT NULL CHECK (length(trim(plan_name)) > 0),
    start_date            DATE         NOT NULL,
    end_date              DATE         NOT NULL,
    status                plan_status  NOT NULL DEFAULT 'draft',
    target_daily_calories NUMERIC(7,2)          CHECK (target_daily_calories > 0),
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT chk_plan_window CHECK (end_date >= start_date)
);

CREATE TABLE IF NOT EXISTS meal_plan_entries (
    entry_id       SERIAL PRIMARY KEY,
    plan_id        INT            NOT NULL
                       REFERENCES meal_plans(plan_id) ON DELETE CASCADE,
    recipe_id      INT            NOT NULL
                       REFERENCES recipes(recipe_id) ON DELETE RESTRICT,
    scheduled_date DATE           NOT NULL,
    meal_slot      meal_slot_type NOT NULL,
    servings       NUMERIC(4,2)   NOT NULL DEFAULT 1 CHECK (servings > 0),
    UNIQUE (plan_id, scheduled_date, meal_slot)
);

CREATE TABLE IF NOT EXISTS recipe_embeddings (
    embedding_id          SERIAL PRIMARY KEY,
    recipe_id             INT          NOT NULL UNIQUE
                              REFERENCES recipes(recipe_id) ON DELETE CASCADE,
    embedding_source_text TEXT         NOT NULL,
    embedding             vector(384)  NOT NULL,
    model_name            VARCHAR(120) NOT NULL,
    model_dim             SMALLINT     NOT NULL CHECK (model_dim = 384),
    content_hash          CHAR(64)     NOT NULL,
    generated_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON COLUMN recipe_embeddings.embedding_source_text IS
    'The exact projected string that was embedded. Stored for reproducibility '
    'and so the projection is checkable rather than merely asserted.';
COMMENT ON COLUMN recipe_embeddings.content_hash IS
    'SHA-256 of embedding_source_text. Lets ingestion skip unchanged recipes, '
    'making the embed step idempotent.';
COMMENT ON COLUMN recipe_embeddings.model_name IS
    'Guards against mixing embedding spaces. A vector produced by a different '
    'model is not comparable even at identical dimensionality.';

CREATE TABLE IF NOT EXISTS search_queries (
    query_id        SERIAL PRIMARY KEY,
    user_id         INT         REFERENCES users(user_id) ON DELETE SET NULL,
    raw_query       TEXT        NOT NULL,
    query_embedding vector(384),
    filters_applied JSONB,
    result_count    SMALLINT    CHECK (result_count >= 0),
    top_recipe_id   INT         REFERENCES recipes(recipe_id) ON DELETE SET NULL,
    searched_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS nutrition_audit_log (
    log_id             SERIAL PRIMARY KEY,
    recipe_id          INT          NOT NULL
                           REFERENCES recipes(recipe_id) ON DELETE CASCADE,
    changed_by         INT          REFERENCES users(user_id) ON DELETE SET NULL,
    old_total_calories NUMERIC(8,2),
    new_total_calories NUMERIC(8,2),
    change_reason      VARCHAR(160),
    changed_at         TIMESTAMPTZ  NOT NULL DEFAULT now()
);

COMMENT ON COLUMN nutrition_audit_log.changed_by IS
    'Read from the session GUC app.user_id when the application sets it. '
    'NULL for direct psql edits, which is itself informative.';

CREATE INDEX IF NOT EXISTS idx_emb_hnsw
    ON recipe_embeddings USING hnsw (embedding vector_cosine_ops);

CREATE INDEX IF NOT EXISTS idx_ri_recipe
    ON recipe_ingredients (recipe_id);

CREATE INDEX IF NOT EXISTS idx_ri_ingredient
    ON recipe_ingredients (ingredient_id);

CREATE INDEX IF NOT EXISTS idx_recipes_protein
    ON recipes (total_protein_g);
CREATE INDEX IF NOT EXISTS idx_recipes_calories
    ON recipes (total_calories);

CREATE INDEX IF NOT EXISTS idx_recipes_facets
    ON recipes (cuisine, difficulty);

CREATE INDEX IF NOT EXISTS idx_recipes_published
    ON recipes (recipe_id) WHERE is_published;

CREATE INDEX IF NOT EXISTS idx_recipes_total_time
    ON recipes ((COALESCE(prep_time_min,0) + COALESCE(cook_time_min,0)));

CREATE INDEX IF NOT EXISTS idx_rdt_tag
    ON recipe_dietary_tags (tag_id);

CREATE INDEX IF NOT EXISTS idx_mpe_plan_date
    ON meal_plan_entries (plan_id, scheduled_date);
CREATE INDEX IF NOT EXISTS idx_meal_plans_user
    ON meal_plans (user_id, status);

CREATE INDEX IF NOT EXISTS idx_ratings_recipe
    ON recipe_ratings (recipe_id);

CREATE INDEX IF NOT EXISTS idx_recipes_fts
    ON recipes USING gin (
        to_tsvector('english',
            title || ' ' || COALESCE(description, '') || ' ' || COALESCE(cuisine, ''))
    );

CREATE INDEX IF NOT EXISTS idx_search_recent
    ON search_queries (searched_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_recipe
    ON nutrition_audit_log (recipe_id, changed_at DESC);

CREATE OR REPLACE FUNCTION fn_current_app_user()
RETURNS INT LANGUAGE plpgsql STABLE AS $$
DECLARE
    v TEXT;
BEGIN
    v := current_setting('app.user_id', true);
    IF v IS NULL OR v = '' THEN
        RETURN NULL;
    END IF;
    RETURN v::INT;
EXCEPTION WHEN others THEN
    RETURN NULL;
END; $$;

CREATE OR REPLACE FUNCTION fn_apply_recipe_nutrition(
    p_recipe_id INT,
    p_reason    VARCHAR(160)
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_old_cal NUMERIC(8,2);
    v_cal  NUMERIC(8,2);
    v_pro  NUMERIC(7,2);
    v_carb NUMERIC(7,2);
    v_fat  NUMERIC(7,2);
BEGIN

    SELECT total_calories INTO v_old_cal
      FROM recipes
     WHERE recipe_id = p_recipe_id;

    IF NOT FOUND THEN

        RETURN;
    END IF;

    SELECT COALESCE(SUM(i.calories_per_100g * ri.quantity_g / 100.0), 0),
           COALESCE(SUM(i.protein_per_100g  * ri.quantity_g / 100.0), 0),
           COALESCE(SUM(i.carbs_per_100g    * ri.quantity_g / 100.0), 0),
           COALESCE(SUM(i.fat_per_100g      * ri.quantity_g / 100.0), 0)
      INTO v_cal, v_pro, v_carb, v_fat
      FROM recipe_ingredients ri
      JOIN ingredients i ON i.ingredient_id = ri.ingredient_id
     WHERE ri.recipe_id = p_recipe_id;

    UPDATE recipes
       SET total_calories  = v_cal,
           total_protein_g = v_pro,
           total_carbs_g   = v_carb,
           total_fat_g     = v_fat,
           updated_at      = now()
     WHERE recipe_id = p_recipe_id;

    INSERT INTO nutrition_audit_log
        (recipe_id, changed_by, old_total_calories, new_total_calories, change_reason)
    VALUES
        (p_recipe_id, fn_current_app_user(), v_old_cal, v_cal, p_reason);
END; $$;

CREATE OR REPLACE FUNCTION fn_recalc_recipe_nutrition()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_reason VARCHAR(160) := TG_OP || ' on recipe_ingredients';
BEGIN
    IF TG_OP = 'INSERT' THEN
        PERFORM fn_apply_recipe_nutrition(NEW.recipe_id, v_reason);

    ELSIF TG_OP = 'DELETE' THEN
        PERFORM fn_apply_recipe_nutrition(OLD.recipe_id, v_reason);

    ELSE
        PERFORM fn_apply_recipe_nutrition(NEW.recipe_id, v_reason);

        IF OLD.recipe_id IS DISTINCT FROM NEW.recipe_id THEN
            PERFORM fn_apply_recipe_nutrition(
                OLD.recipe_id, v_reason || ' (row moved out)');
        END IF;
    END IF;

    RETURN NULL;
END; $$;

DROP TRIGGER IF EXISTS trg_recalc_nutrition ON recipe_ingredients;
CREATE TRIGGER trg_recalc_nutrition
    AFTER INSERT OR UPDATE OR DELETE ON recipe_ingredients
    FOR EACH ROW EXECUTE FUNCTION fn_recalc_recipe_nutrition();

CREATE OR REPLACE FUNCTION fn_guard_derived_nutrition()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF current_setting('app.recalc_in_progress', true) = 'on' THEN
        RETURN NEW;
    END IF;

    IF NEW.total_calories  IS DISTINCT FROM OLD.total_calories
    OR NEW.total_protein_g IS DISTINCT FROM OLD.total_protein_g
    OR NEW.total_carbs_g   IS DISTINCT FROM OLD.total_carbs_g
    OR NEW.total_fat_g     IS DISTINCT FROM OLD.total_fat_g THEN
        RAISE EXCEPTION
            'recipes.total_* are derived columns maintained by '
            'trg_recalc_nutrition; modify recipe_ingredients instead'
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION fn_apply_recipe_nutrition(
    p_recipe_id INT,
    p_reason    VARCHAR(160)
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_old_cal NUMERIC(8,2);
    v_cal  NUMERIC(8,2);
    v_pro  NUMERIC(7,2);
    v_carb NUMERIC(7,2);
    v_fat  NUMERIC(7,2);
BEGIN
    SELECT total_calories INTO v_old_cal
      FROM recipes WHERE recipe_id = p_recipe_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(i.calories_per_100g * ri.quantity_g / 100.0), 0),
           COALESCE(SUM(i.protein_per_100g  * ri.quantity_g / 100.0), 0),
           COALESCE(SUM(i.carbs_per_100g    * ri.quantity_g / 100.0), 0),
           COALESCE(SUM(i.fat_per_100g      * ri.quantity_g / 100.0), 0)
      INTO v_cal, v_pro, v_carb, v_fat
      FROM recipe_ingredients ri
      JOIN ingredients i ON i.ingredient_id = ri.ingredient_id
     WHERE ri.recipe_id = p_recipe_id;

    PERFORM set_config('app.recalc_in_progress', 'on', true);

    UPDATE recipes
       SET total_calories  = v_cal,
           total_protein_g = v_pro,
           total_carbs_g   = v_carb,
           total_fat_g     = v_fat,
           updated_at      = now()
     WHERE recipe_id = p_recipe_id;

    PERFORM set_config('app.recalc_in_progress', 'off', true);

    INSERT INTO nutrition_audit_log
        (recipe_id, changed_by, old_total_calories, new_total_calories, change_reason)
    VALUES
        (p_recipe_id, fn_current_app_user(), v_old_cal, v_cal, p_reason);
END; $$;

DROP TRIGGER IF EXISTS trg_guard_derived ON recipes;
CREATE TRIGGER trg_guard_derived
    BEFORE UPDATE ON recipes
    FOR EACH ROW EXECUTE FUNCTION fn_guard_derived_nutrition();

CREATE OR REPLACE FUNCTION fn_entry_within_plan_window()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_start DATE;
    v_end   DATE;
BEGIN
    SELECT start_date, end_date INTO v_start, v_end
      FROM meal_plans WHERE plan_id = NEW.plan_id;

    IF NEW.scheduled_date < v_start OR NEW.scheduled_date > v_end THEN
        RAISE EXCEPTION
            'scheduled_date % falls outside plan window % .. %',
            NEW.scheduled_date, v_start, v_end
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_entry_window ON meal_plan_entries;
CREATE TRIGGER trg_entry_window
    BEFORE INSERT OR UPDATE ON meal_plan_entries
    FOR EACH ROW EXECUTE FUNCTION fn_entry_within_plan_window();

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

DROP TRIGGER IF EXISTS trg_embedding_stale ON recipes;
CREATE TRIGGER trg_embedding_stale
    AFTER UPDATE ON recipes
    FOR EACH ROW EXECUTE FUNCTION fn_mark_embedding_stale();

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

CREATE OR REPLACE FUNCTION fn_strict_exclusions(p_user_id INT)
RETURNS INT[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(tag_id), '{}')
      FROM user_dietary_preferences
     WHERE user_id = p_user_id AND strictness = 'strict';
$$;

CREATE OR REPLACE PROCEDURE sp_generate_meal_plan(
    p_user_id     INT,
    p_plan_name   VARCHAR(140),
    p_start_date  DATE,
    p_end_date    DATE,
    p_target_kcal NUMERIC DEFAULT 2000,
    INOUT p_plan_id INT DEFAULT NULL
)
LANGUAGE plpgsql AS $$
DECLARE
    v_excluded  INT[];
    v_day       DATE;
    v_slot      meal_slot_type;
    v_share     NUMERIC;
    v_recipe    INT;
    v_used      INT[] := '{}';
    v_slots     meal_slot_type[] := ARRAY['breakfast','lunch','dinner']::meal_slot_type[];

    v_weights   NUMERIC[] := ARRAY[0.25, 0.35, 0.40];
    v_i         INT;
BEGIN
    IF p_end_date < p_start_date THEN
        RAISE EXCEPTION 'end_date % precedes start_date %', p_end_date, p_start_date
            USING ERRCODE = 'check_violation';
    END IF;

    v_excluded := fn_strict_exclusions(p_user_id);

    INSERT INTO meal_plans
        (user_id, plan_name, start_date, end_date, status, target_daily_calories)
    VALUES
        (p_user_id, p_plan_name, p_start_date, p_end_date, 'draft', p_target_kcal)
    RETURNING plan_id INTO p_plan_id;

    v_day := p_start_date;
    WHILE v_day <= p_end_date LOOP
        FOR v_i IN 1 .. array_length(v_slots, 1) LOOP
            v_slot  := v_slots[v_i];
            v_share := p_target_kcal * v_weights[v_i];

            SELECT r.recipe_id INTO v_recipe
              FROM recipes r
             WHERE r.is_published
               AND r.total_calories > 0
               AND NOT EXISTS (
                     SELECT 1 FROM recipe_dietary_tags x
                      WHERE x.recipe_id = r.recipe_id
                        AND x.tag_id = ANY(v_excluded))
             ORDER BY (r.recipe_id = ANY(v_used)),
                      abs(r.total_calories / r.servings - v_share)
             LIMIT 1;

            IF v_recipe IS NULL THEN
                RAISE EXCEPTION
                    'no eligible recipe for % on % (dietary constraints too '
                    'restrictive or corpus too small)', v_slot, v_day
                    USING ERRCODE = 'no_data_found';
            END IF;

            INSERT INTO meal_plan_entries
                (plan_id, recipe_id, scheduled_date, meal_slot, servings)
            VALUES (p_plan_id, v_recipe, v_day, v_slot, 1);

            v_used := array_append(v_used, v_recipe);
        END LOOP;
        v_day := v_day + 1;
    END LOOP;

    UPDATE meal_plans SET status = 'active' WHERE plan_id = p_plan_id;
END; $$;

CREATE OR REPLACE FUNCTION sp_log_search(
    p_user_id   INT,
    p_raw_query TEXT,
    p_embedding vector(384),
    p_filters   JSONB,
    p_count     INT,
    p_top       INT
) RETURNS INT LANGUAGE sql AS $$
    INSERT INTO search_queries
        (user_id, raw_query, query_embedding, filters_applied, result_count, top_recipe_id)
    VALUES
        (p_user_id, p_raw_query, p_embedding, p_filters, p_count, p_top)
    RETURNING query_id;
$$;

CREATE OR REPLACE FUNCTION fn_recipe_embedding_source(p_recipe_id INT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT r.title
           || '. ' || COALESCE(r.description, '')
           || ' Cuisine: ' || COALESCE(r.cuisine, 'any') || '.'
           || ' Tags: '    || COALESCE(
                (SELECT string_agg(dt.tag_name, ', ' ORDER BY dt.tag_name)
                   FROM recipe_dietary_tags rdt
                   JOIN dietary_tags dt ON dt.tag_id = rdt.tag_id
                  WHERE rdt.recipe_id = r.recipe_id), 'none') || '.'
           || ' Ingredients: ' || COALESCE(
                (SELECT string_agg(i.name, ', ' ORDER BY ri.quantity_g DESC)
                   FROM recipe_ingredients ri
                   JOIN ingredients i ON i.ingredient_id = ri.ingredient_id
                  WHERE ri.recipe_id = r.recipe_id), 'none') || '.'
           || ' Total time: '
           || (COALESCE(r.prep_time_min,0) + COALESCE(r.cook_time_min,0))
           || ' minutes. Difficulty: ' || COALESCE(r.difficulty::TEXT, 'unspecified') || '.'
      FROM recipes r
     WHERE r.recipe_id = p_recipe_id;
$$;

CREATE OR REPLACE VIEW v_recipe_nutrition_per_serving AS
SELECT r.recipe_id,
       r.title,
       r.cuisine,
       r.difficulty,
       r.servings,
       ROUND(r.total_calories  / r.servings, 1) AS kcal_per_serving,
       ROUND(r.total_protein_g / r.servings, 1) AS protein_g_per_serving,
       ROUND(r.total_carbs_g   / r.servings, 1) AS carbs_g_per_serving,
       ROUND(r.total_fat_g     / r.servings, 1) AS fat_g_per_serving,
       COALESCE(r.prep_time_min, 0) + COALESCE(r.cook_time_min, 0) AS total_time_min,
       (SELECT string_agg(dt.tag_name, ', ' ORDER BY dt.tag_name)
          FROM recipe_dietary_tags rdt
          JOIN dietary_tags dt ON dt.tag_id = rdt.tag_id
         WHERE rdt.recipe_id = r.recipe_id) AS tags,
       r.is_published
  FROM recipes r;

CREATE OR REPLACE VIEW v_recipe_rating_summary AS
SELECT r.recipe_id,
       r.title,
       COUNT(rr.rating_id)                              AS review_count,
       ROUND(AVG(rr.rating)::NUMERIC, 2)                AS avg_rating,
       MIN(rr.rating)                                   AS lowest,
       MAX(rr.rating)                                   AS highest,
       COUNT(*) FILTER (WHERE rr.rating >= 4)           AS positive_reviews
  FROM recipes r
  JOIN recipe_ratings rr ON rr.recipe_id = r.recipe_id
 GROUP BY r.recipe_id, r.title
HAVING COUNT(rr.rating_id) >= 3;

CREATE OR REPLACE VIEW v_meal_plan_daily_rollup AS
SELECT mp.plan_id,
       mp.user_id,
       mp.plan_name,
       mpe.scheduled_date,
       COUNT(*)                                                   AS meals_planned,
       ROUND(SUM(r.total_calories  / r.servings * mpe.servings), 1) AS kcal_total,
       ROUND(SUM(r.total_protein_g / r.servings * mpe.servings), 1) AS protein_g_total,
       ROUND(SUM(r.total_carbs_g   / r.servings * mpe.servings), 1) AS carbs_g_total,
       ROUND(SUM(r.total_fat_g     / r.servings * mpe.servings), 1) AS fat_g_total,
       mp.target_daily_calories,
       CASE
         WHEN mp.target_daily_calories IS NULL THEN NULL
         ELSE ROUND(SUM(r.total_calories / r.servings * mpe.servings)
                    - mp.target_daily_calories, 1)
       END AS kcal_variance
  FROM meal_plans mp
  JOIN meal_plan_entries mpe ON mpe.plan_id = mp.plan_id
  JOIN recipes r             ON r.recipe_id = mpe.recipe_id
 GROUP BY mp.plan_id, mp.user_id, mp.plan_name,
          mpe.scheduled_date, mp.target_daily_calories;

CREATE OR REPLACE VIEW v_ingredient_usage AS
SELECT i.ingredient_id,
       i.name,
       i.category,
       COUNT(DISTINCT ri.recipe_id)                         AS used_in_recipes,
       ROUND(AVG(ri.quantity_g), 1)                         AS avg_quantity_g,
       RANK() OVER (ORDER BY COUNT(DISTINCT ri.recipe_id) DESC) AS usage_rank,
       (COUNT(ri.recipe_ingredient_id) > 0)                 AS deletion_blocked
  FROM ingredients i
  LEFT JOIN recipe_ingredients ri ON ri.ingredient_id = i.ingredient_id
 GROUP BY i.ingredient_id, i.name, i.category;

CREATE OR REPLACE VIEW v_search_analytics AS
SELECT date_trunc('day', sq.searched_at)::DATE AS search_day,
       COUNT(*)                                AS searches,
       COUNT(DISTINCT sq.user_id)              AS distinct_users,
       ROUND(AVG(sq.result_count), 2)          AS avg_results,
       COUNT(*) FILTER (WHERE sq.result_count = 0) AS zero_result_searches
  FROM search_queries sq
 GROUP BY 1
 ORDER BY 1 DESC;

-- =====================================================================
-- SECTION A  --  INSERT
-- =====================================================================

INSERT INTO users (full_name, email, password_hash, role)
VALUES ('Asha Rao', 'asha@example.com', '$argon2id$v=19$m=65536,t=3,p=4$...', 'registered_user')
RETURNING user_id, created_at;

INSERT INTO dietary_tags (tag_name, tag_type, description) VALUES

    ('vegan',             'diet',           'Contains no animal products'),
    ('vegetarian',        'diet',           'Contains no meat or fish'),
    ('gluten_free',       'diet',           'Contains no gluten-bearing grains'),

    ('contains_dairy',    'allergen',       'Includes milk-derived ingredients'),
    ('contains_nuts',     'allergen',       'Includes tree nuts or peanuts'),
    ('contains_shellfish','allergen',       'Includes crustaceans or molluscs'),
    ('contains_egg',      'allergen',       'Includes egg'),
    ('contains_soy',      'allergen',       'Includes soy'),

    ('high_protein',      'nutrition_goal', 'At least 25 g protein per serving'),
    ('low_carb',          'nutrition_goal', 'At most 20 g carbohydrate per serving');

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

INSERT INTO recipe_dietary_tags (recipe_id, tag_id)
SELECT r.recipe_id,
       (SELECT tag_id FROM dietary_tags WHERE tag_name = 'high_protein')
  FROM recipes r
 WHERE r.total_protein_g / r.servings >= 25
ON CONFLICT (recipe_id, tag_id) DO NOTHING;

INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g, prep_note)
VALUES
    ($1, (SELECT ingredient_id FROM ingredients WHERE name = 'chicken breast'), 300, 'diced'),
    ($1, (SELECT ingredient_id FROM ingredients WHERE name = 'olive oil'),       15, NULL),
    ($1, (SELECT ingredient_id FROM ingredients WHERE name = 'garlic'),           9, 'minced');

-- =====================================================================
-- SECTION B  --  UPDATE
-- =====================================================================

UPDATE recipes
   SET is_published = TRUE
 WHERE recipe_id = $1
   AND author_id  = $2;

UPDATE meal_plans
   SET target_daily_calories = (
         SELECT ROUND(AVG(r.total_calories / r.servings) * 3, 0)
           FROM recipes r
          WHERE r.is_published)
 WHERE plan_id = $1
   AND target_daily_calories IS NULL;

UPDATE meal_plan_entries mpe
   SET servings = 2
  FROM meal_plans mp
 WHERE mpe.plan_id = mp.plan_id
   AND mp.user_id  = $1
   AND mp.status   = 'active';

UPDATE recipe_ingredients
   SET quantity_g = 450
 WHERE recipe_id = $1
   AND ingredient_id = (SELECT ingredient_id FROM ingredients WHERE name = 'chicken breast');

UPDATE users SET is_active = FALSE WHERE user_id = $1;

-- =====================================================================
-- SECTION C  --  DELETE
-- =====================================================================

DELETE FROM recipe_ingredients
 WHERE recipe_id = $1 AND ingredient_id = $2;

DELETE FROM meal_plans mp
 WHERE mp.status = 'draft'
   AND mp.created_at < now() - INTERVAL '30 days'
   AND NOT EXISTS (SELECT 1 FROM meal_plan_entries e WHERE e.plan_id = mp.plan_id);

DELETE FROM recipes WHERE recipe_id = $1;

-- =====================================================================
-- SECTION D  --  SELECT: joins, grouping, subqueries, CTEs, window functions
-- =====================================================================

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

SELECT r.recipe_id, r.title,
       COUNT(rr.rating_id)               AS review_count,
       COALESCE(ROUND(AVG(rr.rating), 2), 0) AS avg_rating
  FROM recipes r
  LEFT JOIN recipe_ratings rr ON rr.recipe_id = r.recipe_id
 WHERE r.is_published
 GROUP BY r.recipe_id, r.title
 ORDER BY avg_rating DESC NULLS LAST, review_count DESC;

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

SELECT r.title,
       r.total_calories,
       (SELECT COUNT(*) FROM recipe_ingredients ri WHERE ri.recipe_id = r.recipe_id)
           AS ingredient_count
  FROM recipes r
 WHERE r.is_published
 ORDER BY ingredient_count DESC
 LIMIT 10;

SELECT r.title, r.cuisine, ROUND(r.total_calories / r.servings, 1) AS kcal
  FROM recipes r
 WHERE r.total_calories / r.servings > (
         SELECT AVG(r2.total_calories / r2.servings)
           FROM recipes r2
          WHERE r2.cuisine = r.cuisine AND r2.is_published)
   AND r.is_published
 ORDER BY r.cuisine, kcal DESC;

SELECT r.recipe_id, r.title
  FROM recipes r
 WHERE r.is_published
   AND NOT EXISTS (
         SELECT 1
           FROM recipe_dietary_tags rdt
          WHERE rdt.recipe_id = r.recipe_id
            AND rdt.tag_id IN (SELECT tag_id FROM dietary_tags
                                WHERE tag_name IN ('contains_dairy')));

SELECT r.recipe_id, r.title
  FROM recipes r
 WHERE r.is_published
   AND NOT EXISTS (
         SELECT 1
           FROM recipe_ingredients ri
           JOIN ingredients i ON i.ingredient_id = ri.ingredient_id
          WHERE ri.recipe_id = r.recipe_id
            AND i.category = 'nut_seed');

SELECT r.title, rr.rating
  FROM recipes r
  JOIN recipe_ratings rr ON rr.recipe_id = r.recipe_id
 WHERE rr.user_id = $1
   AND r.recipe_id IN (SELECT recipe_id FROM recipe_ratings
                        WHERE user_id = $1 AND rating >= 4);

SELECT a.title AS recipe_a, b.title AS recipe_b, a.cuisine
  FROM recipes a
  JOIN recipes b
    ON a.cuisine = b.cuisine
   AND a.recipe_id < b.recipe_id
   AND abs(a.total_calories - b.total_calories) < 50
 WHERE a.is_published AND b.is_published;

SELECT i.name FROM ingredients i
  JOIN recipe_ingredients ri ON ri.ingredient_id = i.ingredient_id
  JOIN recipes r ON r.recipe_id = ri.recipe_id
 WHERE r.cuisine = 'Italian'
EXCEPT
SELECT i.name FROM ingredients i
  JOIN recipe_ingredients ri ON ri.ingredient_id = i.ingredient_id
  JOIN recipes r ON r.recipe_id = ri.recipe_id
 WHERE r.cuisine = 'Indian';

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

-- =====================================================================
-- SECTION E  --  SEARCH: lexical full-text, vector similarity, hybrid
-- =====================================================================

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

SELECT r.recipe_id, r.title,
       ROUND((1 - (e.embedding <=> $1::vector))::NUMERIC, 4) AS similarity
  FROM recipe_embeddings e
  JOIN recipes r ON r.recipe_id = e.recipe_id
 ORDER BY e.embedding <=> $1::vector
 LIMIT 10;

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
   AND r.total_protein_g / r.servings >= $2
   AND (COALESCE(r.prep_time_min,0) + COALESCE(r.cook_time_min,0)) <= $3
   AND NOT EXISTS (
         SELECT 1 FROM recipe_dietary_tags rdt
          WHERE rdt.recipe_id = r.recipe_id
            AND rdt.tag_id = ANY($4::INT[]))
 ORDER BY e.embedding <=> $1::vector
 LIMIT $5;

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

SELECT * FROM fn_search_recipes(
    p_query_embedding := $1::vector,
    p_min_protein     := 25,
    p_max_total_time  := 30,
    p_exclude_tags    := fn_strict_exclusions($2),
    p_limit           := 10);

SELECT sp_log_search($1, $2, $3::vector, $4::jsonb, $5, $6);

-- =====================================================================
-- SECTION F  --  TRANSACTIONS: commit, rollback, savepoint, procedure call
-- =====================================================================

BEGIN;
    SELECT set_config('app.user_id', '1', true);

    INSERT INTO meal_plans (user_id, plan_name, start_date, end_date, status)
    VALUES (1, 'Week of 6 October', DATE '2026-10-06', DATE '2026-10-12', 'draft')
    RETURNING plan_id \gset

    INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot, servings)
    VALUES (:plan_id, 1, DATE '2026-10-06', 'breakfast', 1),
           (:plan_id, 2, DATE '2026-10-06', 'lunch',     1),
           (:plan_id, 3, DATE '2026-10-06', 'dinner',    2);

    UPDATE meal_plans SET status = 'active' WHERE plan_id = :plan_id;
COMMIT;

BEGIN;
    INSERT INTO meal_plans (user_id, plan_name, start_date, end_date)
    VALUES (1, 'Doomed plan', DATE '2026-10-06', DATE '2026-10-08')
    RETURNING plan_id \gset

    INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
    VALUES (:plan_id, 1, DATE '2026-10-06', 'lunch');
    INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
    VALUES (:plan_id, 2, DATE '2026-10-06', 'lunch');
ROLLBACK;

SELECT COUNT(*) AS should_be_zero FROM meal_plans WHERE plan_name = 'Doomed plan';

BEGIN;
    INSERT INTO recipe_ratings (recipe_id, user_id, rating, review_text)
    VALUES (1, 1, 5, 'Excellent');

    SAVEPOINT before_risky;
    INSERT INTO recipe_ratings (recipe_id, user_id, rating, review_text)
    VALUES (1, 1, 4, 'Duplicate -- violates UNIQUE');
    ROLLBACK TO SAVEPOINT before_risky;

COMMIT;

CALL sp_generate_meal_plan(
    p_user_id     := 1,
    p_plan_name   := 'Generated week',
    p_start_date  := DATE '2026-10-13',
    p_end_date    := DATE '2026-10-17',
    p_target_kcal := 2100,
    p_plan_id     := NULL);

BEGIN;
    SELECT status FROM meal_plans WHERE plan_id = $1 FOR UPDATE;
    UPDATE meal_plans SET status = 'completed' WHERE plan_id = $1;
COMMIT;

-- =====================================================================
-- SECTION G  --  READING THE VIEWS
-- =====================================================================

SELECT * FROM v_recipe_nutrition_per_serving
 WHERE kcal_per_serving < 600 AND protein_g_per_serving >= 25
 ORDER BY protein_g_per_serving DESC;

SELECT * FROM v_recipe_rating_summary ORDER BY avg_rating DESC LIMIT 10;

SELECT * FROM v_meal_plan_daily_rollup
 WHERE plan_id = $1 ORDER BY scheduled_date;

SELECT * FROM v_ingredient_usage
 WHERE deletion_blocked ORDER BY usage_rank LIMIT 15;

SELECT * FROM v_search_analytics LIMIT 14;

-- =====================================================================
-- SECTION H  --  AUDIT AND CORRECTNESS QUERIES
-- =====================================================================

SELECT nal.log_id, nal.changed_at, u.full_name AS changed_by,
       nal.old_total_calories, nal.new_total_calories,
       ROUND(nal.new_total_calories - COALESCE(nal.old_total_calories, 0), 2) AS delta,
       nal.change_reason
  FROM nutrition_audit_log nal
  LEFT JOIN users u ON u.user_id = nal.changed_by
 WHERE nal.recipe_id = $1
 ORDER BY nal.changed_at DESC;

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

SELECT r.recipe_id, r.title
  FROM recipes r
  LEFT JOIN recipe_embeddings e ON e.recipe_id = r.recipe_id
 WHERE r.is_published AND e.embedding_id IS NULL;

SELECT r.recipe_id, r.title, e.generated_at
  FROM recipe_embeddings e
  JOIN recipes r ON r.recipe_id = e.recipe_id
 WHERE e.content_hash = repeat('0', 64);

EXPLAIN ANALYZE
SELECT r.recipe_id
  FROM recipes r
  JOIN recipe_embeddings e ON e.recipe_id = r.recipe_id
 ORDER BY e.embedding <=> (SELECT embedding FROM recipe_embeddings LIMIT 1)
 LIMIT 10;

\set ON_ERROR_STOP off

INSERT INTO users (full_name, email, password_hash)
VALUES ('Impostor', 'asha@example.com', 'x');

INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g)
VALUES (1, 1, 100), (1, 1, 200);

INSERT INTO recipe_ratings (recipe_id, user_id, rating) VALUES (1, 1, 5);
INSERT INTO recipe_ratings (recipe_id, user_id, rating) VALUES (1, 1, 3);

INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
VALUES (1, 1, DATE '2026-10-06', 'lunch');
INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
VALUES (1, 2, DATE '2026-10-06', 'lunch');

INSERT INTO recipe_embeddings
    (recipe_id, embedding_source_text, embedding, model_name, model_dim, content_hash)
VALUES (1, 'dup', array_fill(0.1, ARRAY[384])::vector, 'all-MiniLM-L6-v2', 384, repeat('a',64));

INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g)
VALUES (1, 2, -50);

INSERT INTO recipe_ratings (recipe_id, user_id, rating) VALUES (2, 1, 6);

INSERT INTO recipes (title, instructions, servings) VALUES ('Bad', 'x', 0);

INSERT INTO meal_plans (user_id, plan_name, start_date, end_date)
VALUES (1, 'Backwards', DATE '2026-10-10', DATE '2026-10-01');

INSERT INTO recipe_embeddings
    (recipe_id, embedding_source_text, embedding, model_name, model_dim, content_hash)
VALUES (2, 'x', array_fill(0.1, ARRAY[384])::vector, 'other-model', 768, repeat('b',64));

INSERT INTO users (full_name, email, password_hash)
VALUES ('Case', 'MixedCase@Example.com', 'x');

INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g)
VALUES (999999, 1, 100);

DELETE FROM ingredients WHERE ingredient_id = 1;

DELETE FROM recipes
 WHERE recipe_id IN (SELECT recipe_id FROM meal_plan_entries LIMIT 1);

INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
VALUES (1, 1, DATE '2026-10-07', 'brunch');

UPDATE recipes SET total_calories = 99999 WHERE recipe_id = 1;

INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot)
VALUES (1, 1, DATE '2030-01-01', 'dinner');

\set ON_ERROR_STOP on

BEGIN;
  SELECT set_config('app.user_id', '1', true);

  INSERT INTO recipes (title, instructions, servings, is_published)
  VALUES ('Trigger test', 'n/a', 1, FALSE) RETURNING recipe_id \gset

  INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g)
  VALUES (:recipe_id, (SELECT ingredient_id FROM ingredients WHERE name='chicken breast'), 100);
  SELECT 'after INSERT' AS step, total_calories, total_protein_g
    FROM recipes WHERE recipe_id = :recipe_id;

  UPDATE recipe_ingredients SET quantity_g = 200
   WHERE recipe_id = :recipe_id;
  SELECT 'after UPDATE' AS step, total_calories, total_protein_g
    FROM recipes WHERE recipe_id = :recipe_id;

  DELETE FROM recipe_ingredients WHERE recipe_id = :recipe_id;
  SELECT 'after DELETE' AS step, total_calories, total_protein_g
    FROM recipes WHERE recipe_id = :recipe_id;

  SELECT COUNT(*) AS audit_rows FROM nutrition_audit_log
   WHERE recipe_id = :recipe_id;
ROLLBACK;

BEGIN;
  INSERT INTO recipes (title, instructions, servings) VALUES ('Src','x',1)
    RETURNING recipe_id \gset src_id
  INSERT INTO recipes (title, instructions, servings) VALUES ('Dst','x',1)
    RETURNING recipe_id \gset dst_id

  INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g)
  VALUES (:src_id, (SELECT ingredient_id FROM ingredients WHERE name='rice'), 100);

  UPDATE recipe_ingredients SET recipe_id = :dst_id WHERE recipe_id = :src_id;

  SELECT 'source (must be 0)' AS which, total_calories FROM recipes WHERE recipe_id = :src_id;
  SELECT 'dest (must be 130)' AS which, total_calories FROM recipes WHERE recipe_id = :dst_id;
ROLLBACK;

SELECT r.recipe_id, r.total_calories AS stored,
       ROUND(COALESCE(SUM(i.calories_per_100g * ri.quantity_g / 100.0), 0), 2) AS computed
  FROM recipes r
  LEFT JOIN recipe_ingredients ri ON ri.recipe_id = r.recipe_id
  LEFT JOIN ingredients i ON i.ingredient_id = ri.ingredient_id
 GROUP BY r.recipe_id, r.total_calories
HAVING r.total_calories
       <> ROUND(COALESCE(SUM(i.calories_per_100g * ri.quantity_g / 100.0), 0), 2);

PREPARE inj(TEXT) AS SELECT recipe_id, title FROM recipes WHERE title = $1;
EXECUTE inj('''; DROP TABLE recipes; --');
SELECT COUNT(*) AS recipes_still_present FROM recipes;
DEALLOCATE inj;
