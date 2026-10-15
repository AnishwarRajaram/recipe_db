"""Population steps B5 and B6: recipes, composition, and derived tags.

Usage: python scripts/load_recipes.py seed/recipes.json [--check]
Every ingredient name is validated against the ingredients table first;
any mismatch stops the load. Each recipe is inserted in its own
transaction so the nutrition trigger attributes the change to the author.
"""
import json
import sys

import psycopg2

DIET_TAGS = {"vegan", "vegetarian", "pescatarian", "gluten_free"}

# Allergen tags come from named ingredients, not whole categories, so egg
# is never tagged as dairy and seeds are never tagged as nuts.
ALLERGENS = {
    "contains_dairy": ["milk", "butter", "cheddar cheese", "parmesan", "mozzarella",
                       "feta", "greek yogurt", "heavy cream"],
    "contains_nuts": ["almonds", "cashews", "walnuts", "peanuts", "peanut butter",
                      "pine nuts", "pistachios"],
    "contains_egg": ["egg"],
    "contains_soy": ["tofu", "tempeh", "edamame", "soy sauce"],
    "contains_shellfish": ["shrimp", "mussels"],
}

# Diet tags the composition contradicts are removed after loading.
DIET_CONFLICTS = {
    "vegan": "i.category IN ('poultry','meat','fish','seafood','dairy_egg') OR i.name = 'honey' "
             "OR i.name IN ('fish sauce','chicken broth')",
    "vegetarian": "i.category IN ('poultry','meat','fish','seafood') OR i.name IN ('fish sauce','chicken broth')",
    "pescatarian": "i.category IN ('poultry','meat') OR i.name = 'chicken broth'",
    "gluten_free": "i.name IN ('spaghetti','penne','whole wheat bread','flour tortilla','couscous',"
                   "'all-purpose flour','soy sauce')",
}

GOALS = {
    "high_protein": "r.total_protein_g / r.servings >= 25",
    "low_carb": "r.total_carbs_g / r.servings <= 20",
    "low_calorie": "r.total_calories / r.servings <= 400",
}


def validate(cur, recipes):
    names = sorted({i["name"] for r in recipes for i in r["ingredients"]})
    cur.execute("SELECT DISTINCT x.name FROM unnest(%s::text[]) AS x(name) "
                "LEFT JOIN ingredients i ON i.name = x.name WHERE i.ingredient_id IS NULL", (names,))
    missing = [row[0] for row in cur.fetchall()]
    bad_tags = sorted({t for r in recipes for t in r["diet_tags"]} - DIET_TAGS)
    titles = [r["title"] for r in recipes]
    dupes = sorted({t for t in titles if titles.count(t) > 1})
    for label, items in (("unknown ingredients", missing), ("unknown diet tags", bad_tags),
                         ("duplicate titles", dupes)):
        if items:
            print(f"{label}: {items}")
    return not (missing or bad_tags or dupes)


def insert_recipes(conn, recipes):
    with conn.cursor() as cur:
        cur.execute("SELECT user_id FROM users ORDER BY user_id")
        authors = [row[0] for row in cur.fetchall()]
    for n, r in enumerate(recipes):
        author = authors[n % len(authors)]
        with conn, conn.cursor() as cur:
            cur.execute("SELECT set_config('app.user_id', %s, true)", (str(author),))
            cur.execute(
                "INSERT INTO recipes (title, description, instructions, cuisine, difficulty, "
                "prep_time_min, cook_time_min, servings, author_id, is_published) "
                "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, true) RETURNING recipe_id",
                (r["title"], r["description"], r["instructions"], r["cuisine"], r["difficulty"],
                 r["prep_time_min"], r["cook_time_min"], r["servings"], author))
            rid = cur.fetchone()[0]
            cur.executemany(
                "INSERT INTO recipe_ingredients (recipe_id, ingredient_id, quantity_g, prep_note) "
                "SELECT %s, ingredient_id, %s, %s FROM ingredients WHERE name = %s",
                [(rid, i["quantity_g"], i.get("prep_note"), i["name"]) for i in r["ingredients"]])
            cur.execute(
                "INSERT INTO recipe_dietary_tags (recipe_id, tag_id) "
                "SELECT %s, tag_id FROM dietary_tags WHERE tag_name = ANY(%s) ON CONFLICT DO NOTHING",
                (rid, r["diet_tags"]))


def derive_tags(conn):
    with conn, conn.cursor() as cur:
        for tag, cond in DIET_CONFLICTS.items():
            cur.execute(
                "DELETE FROM recipe_dietary_tags rdt USING dietary_tags t "
                "WHERE rdt.tag_id = t.tag_id AND t.tag_name = %s AND EXISTS ("
                "SELECT 1 FROM recipe_ingredients ri JOIN ingredients i ON i.ingredient_id = ri.ingredient_id "
                f"WHERE ri.recipe_id = rdt.recipe_id AND ({cond}))", (tag,))
            print(f"removed contradicted {tag}: {cur.rowcount}")
        for tag, names in ALLERGENS.items():
            cur.execute(
                "INSERT INTO recipe_dietary_tags (recipe_id, tag_id) "
                "SELECT DISTINCT ri.recipe_id, (SELECT tag_id FROM dietary_tags WHERE tag_name = %s) "
                "FROM recipe_ingredients ri JOIN ingredients i ON i.ingredient_id = ri.ingredient_id "
                "WHERE i.name = ANY(%s) ON CONFLICT DO NOTHING", (tag, names))
        for tag, cond in GOALS.items():
            cur.execute(
                "INSERT INTO recipe_dietary_tags (recipe_id, tag_id) "
                "SELECT r.recipe_id, (SELECT tag_id FROM dietary_tags WHERE tag_name = %s) "
                f"FROM recipes r WHERE {cond} ON CONFLICT DO NOTHING", (tag,))
        cur.execute(
            "INSERT INTO recipe_dietary_tags (recipe_id, tag_id) "
            "SELECT r.recipe_id, (SELECT tag_id FROM dietary_tags WHERE tag_name = 'high_fibre') "
            "FROM recipes r JOIN recipe_ingredients ri ON ri.recipe_id = r.recipe_id "
            "JOIN ingredients i ON i.ingredient_id = ri.ingredient_id "
            "GROUP BY r.recipe_id, r.servings "
            "HAVING sum(ri.quantity_g * coalesce(i.fiber_per_100g, 0) / 100) / r.servings >= 8 "
            "ON CONFLICT DO NOTHING")


def report(cur):
    cur.execute("SELECT count(*), count(*) FILTER (WHERE total_calories > 0), "
                "round(min(total_calories / servings)), round(percentile_cont(0.5) WITHIN GROUP "
                "(ORDER BY total_calories / servings)::numeric), round(max(total_calories / servings)), "
                "round(min(total_protein_g / servings)), round(max(total_protein_g / servings)) FROM recipes")
    print("recipes, with_nutrition, kcal min/median/max, protein min/max:", cur.fetchone())
    cur.execute("SELECT t.tag_name, count(rdt.recipe_id) FROM dietary_tags t "
                "LEFT JOIN recipe_dietary_tags rdt ON rdt.tag_id = t.tag_id GROUP BY t.tag_name ORDER BY 1")
    print("tags:", dict(cur.fetchall()))


def main():
    recipes = json.load(open(sys.argv[1]))
    conn = psycopg2.connect()
    try:
        with conn, conn.cursor() as cur:
            ok = validate(cur, recipes)
        print(f"{len(recipes)} recipes, valid: {ok}")
        if not ok or "--check" in sys.argv:
            sys.exit(0 if ok else 1)
        insert_recipes(conn, recipes)
        derive_tags(conn)
        with conn, conn.cursor() as cur:
            report(cur)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
