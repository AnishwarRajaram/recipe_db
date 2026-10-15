"""Population step B7: ratings and meal plans.

Ratings are skewed towards 4 and 5. About 20 recipes get only one or two
reviews so the HAVING clause in v_recipe_rating_summary hides them.
Two plans are built by hand and two by sp_generate_meal_plan, one of them
for the dairy-strict user.
"""
import random

import psycopg2

REVIEWS = {
    5: ["Excellent, will make again.", "Family favourite now.", "Spot on flavours."],
    4: ["Very good, would add more spice.", "Solid weeknight option.", "Tasty and easy."],
    3: ["Fine but a bit plain.", "Okay, took longer than stated."],
    2: ["Too bland for me.", "Texture was off."],
    1: ["Did not work out."],
}


def ratings(recipes, users):
    rng = random.Random(0)
    rng.shuffle(recipes)
    plan = [(rid, author, rng.choice([1, 2])) for rid, author in recipes[:20]]
    plan += [(rid, author, rng.randint(3, 6)) for rid, author in recipes[20:62]]
    rows = []
    for rid, author, n in plan:
        for uid in rng.sample([u for u in users if u != author], n):
            score = rng.choices([5, 4, 3, 2, 1], weights=[40, 35, 15, 8, 2])[0]
            rows.append((rid, uid, score, rng.choice(REVIEWS[score]) if rng.random() < 0.7 else None))
    return rows


# (email, plan name, start, end, target kcal, tag to draw recipes from)
HAND_PLANS = [
    ("tom.fischer@example.com", "Training block", "2026-10-19", "2026-10-21", 2600, "high_protein"),
    ("mei.lin@example.com", "Plant-based week", "2026-10-19", "2026-10-23", 1900, "vegan"),
]


def main():
    conn = psycopg2.connect()
    try:
        with conn, conn.cursor() as cur:
            cur.execute("SELECT recipe_id, author_id FROM recipes ORDER BY recipe_id")
            recipes = cur.fetchall()
            cur.execute("SELECT user_id FROM users ORDER BY user_id")
            users = [r[0] for r in cur.fetchall()]
            cur.executemany(
                "INSERT INTO recipe_ratings (recipe_id, user_id, rating, review_text) "
                "VALUES (%s, %s, %s, %s) ON CONFLICT (recipe_id, user_id) DO NOTHING",
                ratings(recipes, users))

        for email, name, start, end, kcal, tag in HAND_PLANS:
            with conn, conn.cursor() as cur:
                cur.execute("SELECT user_id FROM users WHERE email = %s", (email,))
                uid = cur.fetchone()[0]
                cur.execute("SELECT set_config('app.user_id', %s, true)", (str(uid),))
                cur.execute(
                    "INSERT INTO meal_plans (user_id, plan_name, start_date, end_date, status, "
                    "target_daily_calories) VALUES (%s, %s, %s, %s, 'active', %s) RETURNING plan_id",
                    (uid, name, start, end, kcal))
                pid = cur.fetchone()[0]
                cur.execute(
                    "WITH days AS (SELECT d::date AS day, row_number() OVER () AS n "
                    "              FROM generate_series(%s::date, %s::date, interval '1 day') d), "
                    "slots AS (SELECT day, s::meal_slot_type AS slot, row_number() OVER () AS k "
                    "          FROM days, unnest(ARRAY['breakfast','lunch','dinner']) s), "
                    "pool AS (SELECT r.recipe_id, row_number() OVER (ORDER BY r.recipe_id) AS k "
                    "         FROM recipes r JOIN recipe_dietary_tags rdt ON rdt.recipe_id = r.recipe_id "
                    "         JOIN dietary_tags t ON t.tag_id = rdt.tag_id WHERE t.tag_name = %s) "
                    "INSERT INTO meal_plan_entries (plan_id, recipe_id, scheduled_date, meal_slot, servings) "
                    "SELECT %s, p.recipe_id, s.day, s.slot, 1 FROM slots s "
                    "JOIN pool p ON p.k = 1 + (s.k - 1) %% (SELECT count(*) FROM pool)",
                    (start, end, tag, pid))

        for email, name in (("asha.raman@example.com", "Generated week"),
                            ("priya.nair@example.com", "Generated week, dairy-free")):
            with conn, conn.cursor() as cur:
                cur.execute("SELECT user_id FROM users WHERE email = %s", (email,))
                uid = cur.fetchone()[0]
                cur.execute("SELECT set_config('app.user_id', %s, true)", (str(uid),))
                cur.execute("CALL sp_generate_meal_plan(%s, %s, DATE '2026-10-19', DATE '2026-10-23', "
                            "2100, NULL)", (uid, name))

        with conn, conn.cursor() as cur:
            cur.execute("SELECT (SELECT count(*) FROM recipe_ratings), "
                        "(SELECT count(*) FROM v_recipe_rating_summary), "
                        "(SELECT count(DISTINCT recipe_id) FROM recipe_ratings), "
                        "(SELECT count(*) FROM meal_plans), (SELECT count(*) FROM meal_plan_entries)")
            print("ratings, recipes in summary view, recipes rated, plans, entries:", cur.fetchone())
            cur.execute("SELECT count(*) FROM meal_plans p JOIN meal_plan_entries e ON e.plan_id = p.plan_id "
                        "JOIN recipe_dietary_tags rdt ON rdt.recipe_id = e.recipe_id "
                        "JOIN dietary_tags t ON t.tag_id = rdt.tag_id "
                        "WHERE p.plan_name = 'Generated week, dairy-free' AND t.tag_name = 'contains_dairy'")
            print("dairy recipes in dairy-strict plan (must be 0):", cur.fetchone()[0])
            cur.execute("SELECT p.plan_name, count(e.entry_id) FROM meal_plans p "
                        "LEFT JOIN meal_plan_entries e ON e.plan_id = p.plan_id GROUP BY p.plan_id ORDER BY p.plan_id")
            print("entries per plan:", cur.fetchall())
    finally:
        conn.close()


if __name__ == "__main__":
    main()
