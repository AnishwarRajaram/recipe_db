Generate 120 recipes as JSON for a recipe search database. Output in 6 batches of 20 (I will say "next" between batches). Each batch is ONE JSON array, no prose, no markdown fences, no comments.

Each element must follow exactly this shape:
{"title": "...", "description": "...", "cuisine": "...", "difficulty": "easy|medium|hard", "prep_time_min": 10, "cook_time_min": 15, "servings": 2, "diet_tags": ["gluten_free"], "ingredients": [{"name": "chicken breast", "quantity_g": 300, "prep_note": "diced"}], "instructions": "..."}

HARD RULES
1. Ingredient "name" must be copied EXACTLY (lowercase, same spelling) from the ALLOWED INGREDIENTS list below. No other ingredients, no synonyms, no plurals changed. If a dish needs something not listed, pick a different dish.
2. quantity_g = grams for the WHOLE recipe (all servings), a realistic number. prep_note optional, under 40 chars.
3. No nutrition fields at all (no calories, protein, etc.).
4. diet_tags may only use: vegan, vegetarian, pescatarian, gluten_free. Tag only when strictly true for the listed ingredients (e.g. no gluten_free if spaghetti, penne, bread, flour, tortilla, couscous or soy sauce is present; vegan means no meat, fish, egg, dairy, honey). Do not add allergen tags.
5. 5 to 12 ingredients per recipe. servings 1 to 6. Titles unique across all 120.
6. description: one or two sentences describing the dish's character and when you would eat it (mood, occasion, weight, texture). instructions: 3 to 6 sentences of method.

CORPUS SPREAD (across all 120)
- At least 8 cuisines, roughly even, e.g. Italian, Mexican, Indian, Chinese, Japanese, Thai, Mediterranean, Middle Eastern, American, French, Korean.
- Total time (prep + cook): about 40 under 30 min, about 40 from 30 to 60 min, about 40 over 60 min.
- Protein: at least 30 clearly high-protein recipes (about 150 g or more of meat, fish, tofu or legumes PER SERVING) and at least 30 clearly low-protein ones (salads, fruit, grain or vegetable sides, light soups).
- At least 25 recipes containing dairy (milk, butter, cheese, yogurt, cream) and at least 18 containing nuts or peanut butter.
- At least 20 vegan and 15 more vegetarian recipes.
- Near-miss pairs (at least 10 pairs): recipes sharing words but differing in intent, e.g. a rich creamy baked pasta vs a light lemony pasta; a hearty beef chili vs a light bean salad; a sweet banana oat breakfast vs a savoury oat porridge.
- Intent-only matches (at least 15 recipes): dishes that fit phrases like "warming for a cold evening", "light lunch that won't make me sleepy", "hearty vegan comfort food", "quick high-protein dinner without dairy", "something fresh for a hot day", "cosy weekend bake", but whose title and description do NOT use those words; describe them in other terms.

ALLOWED INGREDIENTS
chicken breast, chicken thigh, turkey mince, beef mince, beef sirloin, lamb shoulder, pork tenderloin, bacon, salmon fillet, cod fillet, canned tuna, shrimp, mussels,
egg, milk, butter, cheddar cheese, parmesan, mozzarella, feta, greek yogurt, heavy cream,
almonds, cashews, walnuts, peanuts, peanut butter, pine nuts, pistachios, sesame seeds, chia seeds,
chickpeas, red lentils, black beans, kidney beans, white beans, green peas, edamame, tofu, tempeh,
white rice, brown rice, quinoa, rolled oats, spaghetti, penne, whole wheat bread, flour tortilla, couscous, rice noodles, all-purpose flour,
onion, garlic, tomato, canned tomatoes, spinach, kale, broccoli, cauliflower, carrot, bell pepper, zucchini, mushrooms, sweet potato, potato, cucumber, avocado, eggplant, cabbage, butternut squash, lemon, lime, banana, apple, blueberries, mango,
olive oil, coconut oil, sesame oil, coconut milk, soy sauce, fish sauce, honey, maple syrup, sugar, dijon mustard, tomato paste, red wine vinegar, vegetable broth, chicken broth, ginger, cumin, paprika, chili flakes, turmeric, curry powder, cinnamon, black pepper, salt, basil, cilantro, parsley, rosemary, thyme

Start with batch 1 now.
