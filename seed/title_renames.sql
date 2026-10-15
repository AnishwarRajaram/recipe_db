BEGIN;
SELECT set_config('app.user_id', '1', true);
UPDATE recipes r SET title = v.t FROM (VALUES
 (72,'Beef and Brown Rice Soup with Thyme'),(96,'Ginger Soy Turkey Tortilla Wraps'),
 (97,'Chicken Cutlets in Mushroom Vinegar Sauce'),(101,'Roasted Lemon Salmon with Buttered Peas'),
 (113,'Cumin White Bean Tacos with Avocado'),(120,'Braised Cabbage with Apple'),
 (127,'Slow-Cooked Onion and Celery Confit'),(132,'Long-Simmered Tomato and Carrot Sauce'),
 (134,'Soy-Ginger Roasted Eggplant'),(138,'Baked Almond Barfi'),
 (142,'Sweet Cinnamon Rice Porridge with Walnuts'),(145,'Butternut Squash and Peanut Curry'),
 (146,'Crisp Almond Cookies'),(148,'Roasted Carrot and Potato Confit with Walnuts'),
 (151,'Apple Tart with Almond Cream'),(124,'Korean Soy-Braised Potatoes'),
 (125,'Whole Roasted Spiced Cauliflower'),(126,'Japanese Vegetable Curry'),
 (129,'Potato and Pea Curry'),(130,'Coconut-Roasted Butternut Squash'),
 (131,'Baked Sweet Potatoes with Sesame'),(133,'Rice Kheer with Pistachios'),
 (135,'Peanut and Coconut Vegetable Stew'),(136,'Apple and Almond Gratin'),
 (137,'Soy-Braised Tofu'),(139,'Butternut Squash and Walnut Bake'),
 (140,'Soy-Glazed Braised Carrots'),(141,'Banana Peanut Butter Cake'),
 (143,'Spiced Roasted Sweet Potato with Almonds'),(144,'Celery and Potato Gratin'),
 (147,'Coconut Cinnamon Rice Pudding with Cashews'),(149,'Baked Walnut and Honey Rice Cake'),
 (150,'Soy-Glazed Sweet Potato')) AS v(id, t)
WHERE r.recipe_id = v.id;
UPDATE recipes SET description = replace(description, 'cider vinegar', 'red wine vinegar') WHERE recipe_id = 120;
COMMIT;
