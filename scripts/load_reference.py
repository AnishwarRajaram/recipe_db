"""Population steps B1 to B4: reset, dietary tags, ingredients, users.

Connection settings come from the PG* environment variables (db.env).
Password hashes are bcrypt digests produced by pgcrypto from random
throwaway passwords that are never stored.
"""
import json
import secrets
from pathlib import Path

import psycopg2

ROOT = Path(__file__).resolve().parents[1]

TAGS = [
    ("vegan", "diet", "Contains no animal products"),
    ("vegetarian", "diet", "Contains no meat or fish"),
    ("pescatarian", "diet", "Fish but no other meat"),
    ("gluten_free", "diet", "No gluten-bearing grains"),
    ("contains_dairy", "allergen", "Includes milk-derived ingredients"),
    ("contains_nuts", "allergen", "Includes tree nuts or peanuts"),
    ("contains_egg", "allergen", "Includes egg"),
    ("contains_soy", "allergen", "Includes soy"),
    ("contains_shellfish", "allergen", "Includes crustaceans or molluscs"),
    ("high_protein", "nutrition_goal", "At least 25 g protein per serving"),
    ("low_carb", "nutrition_goal", "At most 20 g carbohydrate per serving"),
    ("low_calorie", "nutrition_goal", "At most 400 kcal per serving"),
    ("high_fibre", "nutrition_goal", "At least 8 g fibre per serving"),
]

USERS = [
    ("Asha Raman", "asha.raman@example.com", "admin"),
    ("Daniel Okafor", "daniel.okafor@example.com", "admin"),
    ("Priya Nair", "priya.nair@example.com", "registered_user"),
    ("Tom Fischer", "tom.fischer@example.com", "registered_user"),
    ("Mei Lin", "mei.lin@example.com", "registered_user"),
    ("Carlos Mendes", "carlos.mendes@example.com", "registered_user"),
    ("Sara Haddad", "sara.haddad@example.com", "registered_user"),
    ("James Whitfield", "james.whitfield@example.com", "registered_user"),
    ("Anika Bose", "anika.bose@example.com", "registered_user"),
    ("Leo Martins", "leo.martins@example.com", "registered_user"),
]

# (email, tag, strictness); priya is the dairy-strict user for the exclusion demo
PREFERENCES = [
    ("priya.nair@example.com", "contains_dairy", "strict"),
    ("priya.nair@example.com", "vegetarian", "preferred"),
    ("tom.fischer@example.com", "contains_nuts", "strict"),
    ("tom.fischer@example.com", "high_protein", "preferred"),
    ("mei.lin@example.com", "vegan", "preferred"),
    ("mei.lin@example.com", "contains_soy", "avoid"),
    ("carlos.mendes@example.com", "contains_shellfish", "strict"),
]

ING_COLS = ["name", "category", "calories_per_100g", "protein_per_100g", "carbs_per_100g",
            "fat_per_100g", "fiber_per_100g", "sodium_mg_per_100g", "source_ref"]


def main():
    ingredients = json.loads((ROOT / "seed" / "ingredients.json").read_text())
    with psycopg2.connect() as conn, conn.cursor() as cur:
        cur.execute("TRUNCATE users, ingredients, recipes, dietary_tags RESTART IDENTITY CASCADE")
        cur.executemany(
            "INSERT INTO dietary_tags (tag_name, tag_type, description) VALUES (%s, %s, %s) "
            "ON CONFLICT (tag_name) DO NOTHING", TAGS)
        updates = ", ".join(f"{c} = EXCLUDED.{c}" for c in ING_COLS[1:])
        cur.executemany(
            f"INSERT INTO ingredients ({', '.join(ING_COLS)}) VALUES ({', '.join(['%s'] * len(ING_COLS))}) "
            f"ON CONFLICT (name) DO UPDATE SET {updates}",
            [[i.get(c) for c in ING_COLS] for i in ingredients])
        cur.executemany(
            "INSERT INTO users (full_name, email, password_hash, role) "
            "VALUES (%s, %s, crypt(%s, gen_salt('bf', 10)), %s) ON CONFLICT (email) DO NOTHING",
            [(n, e, secrets.token_urlsafe(16), r) for n, e, r in USERS])
        cur.executemany(
            "INSERT INTO user_dietary_preferences (user_id, tag_id, strictness) "
            "SELECT u.user_id, t.tag_id, %s FROM users u, dietary_tags t "
            "WHERE u.email = %s AND t.tag_name = %s ON CONFLICT DO NOTHING",
            [(s, e, t) for e, t, s in PREFERENCES])
        cur.execute("SELECT (SELECT count(*) FROM dietary_tags), (SELECT count(*) FROM ingredients), "
                    "(SELECT count(DISTINCT category) FROM ingredients), (SELECT count(*) FROM users), "
                    "(SELECT count(*) FROM user_dietary_preferences), "
                    "(SELECT count(*) FROM users WHERE password_hash LIKE '$2a$%')")
        print("tags, ingredients, categories, users, preferences, bcrypt_hashes:", cur.fetchone())


if __name__ == "__main__":
    main()
