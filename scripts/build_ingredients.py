"""Builds seed/ingredients.json from the USDA SR Legacy CSVs.

Each ingredient maps to one SR Legacy food description; nutrition per 100 g
is read from food_nutrient.csv and the FDC ID is kept as source_ref.
Unmatched descriptions are reported with candidates and left out.
"""
import csv
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
USDA = ROOT / "data" / "usda"
NUTRIENTS = {"1008": "calories_per_100g", "1003": "protein_per_100g",
             "1005": "carbs_per_100g", "1004": "fat_per_100g",
             "1079": "fiber_per_100g", "1093": "sodium_mg_per_100g"}

# name -> (category, SR Legacy description)
MAP = {
    "chicken breast": ("poultry", "Chicken, broiler or fryers, breast, skinless, boneless, meat only, raw"),
    "chicken thigh": ("poultry", "Chicken, broilers or fryers, dark meat, thigh, meat only, raw"),
    "turkey mince": ("poultry", "Turkey, Ground, raw"),
    "beef mince": ("meat", "Beef, ground, 85% lean meat / 15% fat, raw"),
    "beef sirloin": ("meat", "Beef, top sirloin, steak, separable lean and fat, trimmed to 1/8\" fat, choice, raw"),
    "lamb shoulder": ("meat", "Lamb, shoulder, whole (arm and blade), separable lean and fat, trimmed to 1/4\" fat, choice, raw"),
    "pork tenderloin": ("meat", "Pork, fresh, loin, tenderloin, separable lean and fat, raw"),
    "bacon": ("meat", "Pork, cured, bacon, unprepared"),
    "salmon fillet": ("fish", "Fish, salmon, Atlantic, farmed, raw"),
    "cod fillet": ("fish", "Fish, cod, Atlantic, raw"),
    "canned tuna": ("fish", "Fish, tuna, light, canned in water, without salt, drained solids"),
    "shrimp": ("seafood", "Crustaceans, shrimp, raw"),
    "mussels": ("seafood", "Mollusks, mussel, blue, raw"),
    "egg": ("dairy_egg", "Egg, whole, raw, fresh"),
    "milk": ("dairy_egg", "Milk, whole, 3.25% milkfat, with added vitamin D"),
    "butter": ("dairy_egg", "Butter, salted"),
    "cheddar cheese": ("dairy_egg", "Cheese, cheddar"),
    "parmesan": ("dairy_egg", "Cheese, parmesan, hard"),
    "mozzarella": ("dairy_egg", "Cheese, mozzarella, whole milk"),
    "feta": ("dairy_egg", "Cheese, feta"),
    "greek yogurt": ("dairy_egg", "Yogurt, Greek, plain, nonfat"),
    "heavy cream": ("dairy_egg", "Cream, fluid, heavy whipping"),
    "almonds": ("nut_seed", "Nuts, almonds"),
    "cashews": ("nut_seed", "Nuts, cashew nuts, raw"),
    "walnuts": ("nut_seed", "Nuts, walnuts, english"),
    "peanuts": ("nut_seed", "Peanuts, all types, raw"),
    "peanut butter": ("nut_seed", "Peanut butter, smooth style, without salt"),
    "pine nuts": ("nut_seed", "Nuts, pine nuts, dried"),
    "pistachios": ("nut_seed", "Nuts, pistachio nuts, raw"),
    "sesame seeds": ("nut_seed", "Seeds, sesame seeds, whole, dried"),
    "chia seeds": ("nut_seed", "Seeds, chia seeds, dried"),
    "chickpeas": ("legume", "Chickpeas (garbanzo beans, bengal gram), mature seeds, canned, drained, rinsed in tap water"),
    "red lentils": ("legume", "Lentils, pink or red, raw"),
    "black beans": ("legume", "Beans, black, mature seeds, canned, low sodium"),
    "kidney beans": ("legume", "Beans, kidney, red, mature seeds, canned, drained solids"),
    "white beans": ("legume", "Beans, white, mature seeds, canned"),
    "green peas": ("legume", "Peas, green, frozen, unprepared"),
    "edamame": ("legume", "Edamame, frozen, unprepared"),
    "tofu": ("plant_protein", "Tofu, raw, firm, prepared with calcium sulfate"),
    "tempeh": ("plant_protein", "Tempeh"),
    "white rice": ("grain", "Rice, white, long-grain, regular, raw, enriched"),
    "brown rice": ("grain", "Rice, brown, long-grain, raw"),
    "quinoa": ("grain", "Quinoa, uncooked"),
    "rolled oats": ("grain", "Cereals, oats, regular and quick, not fortified, dry"),
    "spaghetti": ("grain", "Pasta, dry, enriched"),
    "penne": ("grain", "Pasta, dry, enriched"),
    "whole wheat bread": ("grain", "Bread, whole-wheat, commercially prepared"),
    "flour tortilla": ("grain", "Tortillas, ready-to-bake or -fry, flour, refrigerated"),
    "couscous": ("grain", "Couscous, dry"),
    "rice noodles": ("grain", "Rice noodles, dry"),
    "all-purpose flour": ("grain", "Wheat flour, white, all-purpose, enriched, bleached"),
    "onion": ("vegetable", "Onions, raw"),
    "garlic": ("vegetable", "Garlic, raw"),
    "tomato": ("vegetable", "Tomatoes, red, ripe, raw, year round average"),
    "canned tomatoes": ("vegetable", "Tomatoes, red, ripe, canned, packed in tomato juice"),
    "spinach": ("vegetable", "Spinach, raw"),
    "kale": ("vegetable", "Kale, raw"),
    "broccoli": ("vegetable", "Broccoli, raw"),
    "cauliflower": ("vegetable", "Cauliflower, raw"),
    "carrot": ("vegetable", "Carrots, raw"),
    "bell pepper": ("vegetable", "Peppers, sweet, red, raw"),
    "zucchini": ("vegetable", "Squash, summer, zucchini, includes skin, raw"),
    "mushrooms": ("vegetable", "Mushrooms, white, raw"),
    "sweet potato": ("vegetable", "Sweet potato, raw, unprepared"),
    "potato": ("vegetable", "Potatoes, flesh and skin, raw"),
    "celery": ("vegetable", "Celery, raw"),
    "cucumber": ("vegetable", "Cucumber, with peel, raw"),
    "avocado": ("fruit", "Avocados, raw, all commercial varieties"),
    "eggplant": ("vegetable", "Eggplant, raw"),
    "cabbage": ("vegetable", "Cabbage, raw"),
    "butternut squash": ("vegetable", "Squash, winter, butternut, raw"),
    "lemon": ("fruit", "Lemons, raw, without peel"),
    "lime": ("fruit", "Limes, raw"),
    "banana": ("fruit", "Bananas, raw"),
    "apple": ("fruit", "Apples, raw, with skin"),
    "blueberries": ("fruit", "Blueberries, raw"),
    "mango": ("fruit", "Mangos, raw"),
    "olive oil": ("fat_oil", "Oil, olive, salad or cooking"),
    "coconut oil": ("fat_oil", "Oil, coconut"),
    "sesame oil": ("fat_oil", "Oil, sesame, salad or cooking"),
    "coconut milk": ("fat_oil", "Nuts, coconut milk, canned (liquid expressed from grated meat and water)"),
    "soy sauce": ("condiment", "Soy sauce made from soy and wheat (shoyu)"),
    "fish sauce": ("condiment", "Sauce, fish, ready-to-serve"),
    "honey": ("condiment", "Honey"),
    "maple syrup": ("condiment", "Syrups, maple"),
    "sugar": ("condiment", "Sugars, granulated"),
    "dijon mustard": ("condiment", "Mustard, prepared, yellow"),
    "tomato paste": ("condiment", "Tomato products, canned, paste, without salt added"),
    "red wine vinegar": ("condiment", "Vinegar, red wine"),
    "vegetable broth": ("condiment", "Soup, vegetable broth, ready to serve"),
    "chicken broth": ("condiment", "Soup, chicken broth, ready-to-serve"),
    "ginger": ("spice", "Ginger root, raw"),
    "cumin": ("spice", "Spices, cumin seed"),
    "paprika": ("spice", "Spices, paprika"),
    "chili flakes": ("spice", "Spices, pepper, red or cayenne"),
    "turmeric": ("spice", "Spices, turmeric, ground"),
    "curry powder": ("spice", "Spices, curry powder"),
    "cinnamon": ("spice", "Spices, cinnamon, ground"),
    "black pepper": ("spice", "Spices, pepper, black"),
    "salt": ("spice", "Salt, table"),
    "basil": ("herb", "Basil, fresh"),
    "cilantro": ("herb", "Coriander (cilantro) leaves, raw"),
    "parsley": ("herb", "Parsley, fresh"),
    "rosemary": ("herb", "Rosemary, fresh"),
    "thyme": ("herb", "Thyme, fresh"),
}


def main():
    by_desc, descs = {}, {}
    with open(USDA / "food.csv", newline="") as f:
        for row in csv.DictReader(f):
            by_desc.setdefault(row["description"].split(" (Includes foods")[0], row["fdc_id"])
            descs[row["fdc_id"]] = row["description"]
    missing = {n: d for n, (_, d) in MAP.items() if d not in by_desc}
    for name, desc in missing.items():
        words = [w for w in desc.lower().replace(",", " ").split() if len(w) > 3][:3]
        cands = [d for d in by_desc if all(w in d.lower() for w in words)][:6]
        print(f"MISS {name!r}: {desc!r}\n   candidates: {cands}")
    ids = {by_desc[d]: n for n, (_, d) in MAP.items() if d in by_desc}
    vals = {}
    with open(USDA / "food_nutrient.csv", newline="") as f:
        for row in csv.DictReader(f):
            if row["fdc_id"] in ids and row["nutrient_id"] in NUTRIENTS:
                vals.setdefault(row["fdc_id"], {})[NUTRIENTS[row["nutrient_id"]]] = float(row["amount"])
    out = []
    for name, (cat, desc) in MAP.items():
        if name in missing:
            continue
        fdc = by_desc[desc]
        v = vals.get(fdc, {})
        if not all(k in v for k in ("calories_per_100g", "protein_per_100g", "carbs_per_100g", "fat_per_100g")):
            print(f"INCOMPLETE {name!r} fdc {fdc}: {v}")
            continue
        out.append({"name": name, "category": cat, **v, "source_ref": f"USDA FDC {fdc}"})
    (ROOT / "seed" / "ingredients.json").write_text(json.dumps(out, indent=1))
    print(f"wrote {len(out)} of {len(MAP)}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
