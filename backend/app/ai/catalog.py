"""Deterministic product knowledge: categories, search terms, and store layouts.

This is generic knowledge about how stores of a given format are usually
organized. It never contains aisle numbers: those only come from database rows.
Layout coordinates are normalized floor-plan units (x: 0 left to 1 right,
y: 0 front of store to 1 back wall) used for rough route ordering.
"""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class CategoryDef:
    slug: str
    name: str
    neighbors: tuple[str, ...]
    terms: tuple[str, ...]


@dataclass(frozen=True)
class ZoneDef:
    name: str
    x: float
    y: float
    categories: tuple[str, ...]


@dataclass(frozen=True)
class LayoutDef:
    key: str
    label: str
    entrance: tuple[float, float]
    checkout: tuple[float, float]
    zones: tuple[ZoneDef, ...]
    _by_category: dict[str, ZoneDef] = field(default_factory=dict, compare=False, repr=False)

    def __post_init__(self):
        for zone in self.zones:
            for slug in zone.categories:
                self._by_category.setdefault(slug, zone)

    def zone_for(self, category_slug: str) -> ZoneDef | None:
        return self._by_category.get(category_slug)


def _c(slug, name, neighbors, terms):
    return CategoryDef(slug, name, tuple(neighbors), tuple(terms))


CATEGORIES: tuple[CategoryDef, ...] = (
    # Fresh
    _c("produce-fruit", "Fruit", ["bananas", "apples", "berries"], [
        "fruit", "banana", "apple", "orange", "lemon", "lime", "grape", "strawberry",
        "blueberry", "raspberry", "blackberry", "berry", "peach", "pear", "plum", "mango",
        "pineapple", "watermelon", "melon", "cantaloupe", "kiwi", "cherry", "avocado",
        "grapefruit", "clementine", "nectarine", "pomegranate", "dragonfruit", "papaya",
    ]),
    _c("produce-veg", "Vegetables", ["lettuce", "tomatoes", "onions"], [
        "vegetable", "veggie", "lettuce", "tomato", "onion", "potato", "sweet potato",
        "carrot", "celery", "broccoli", "cauliflower", "spinach", "kale", "cucumber",
        "pepper", "bell pepper", "jalapeno", "garlic", "ginger", "mushroom", "zucchini",
        "squash", "corn", "green bean", "asparagus", "cabbage", "salad mix", "arugula",
        "cilantro", "parsley", "basil", "mint", "scallion", "green onion", "shallot",
        "beet", "radish", "brussels sprout", "eggplant", "leek", "herb",
    ]),
    _c("flowers", "Flowers & Plants", ["bouquets", "potted plants"], [
        "flower", "bouquet", "rose", "tulip", "sunflower", "orchid", "potted plant",
    ]),
    _c("bakery", "Bread & Bakery", ["bread", "bagels", "tortillas"], [
        "bread", "loaf", "bagel", "baguette", "bun", "hamburger bun", "hot dog bun",
        "roll", "dinner roll", "croissant", "muffin", "english muffin", "tortilla",
        "pita", "naan", "sourdough", "cake", "pie", "donut", "doughnut", "brioche",
    ]),
    _c("dairy", "Milk & Dairy", ["milk", "butter", "yogurt"], [
        "milk", "whole milk", "skim milk", "almond milk", "oat milk", "soy milk",
        "chocolate milk", "lactose free milk", "cream", "heavy cream", "whipping cream",
        "half and half", "butter", "yogurt", "greek yogurt", "sour cream",
        "cottage cheese", "kefir", "whipped cream",
    ]),
    _c("eggs", "Eggs", ["milk", "butter"], ["egg", "egg white"]),
    _c("cheese", "Cheese", ["shredded cheese", "cream cheese", "butter"], [
        "cheese", "cheddar", "mozzarella", "parmesan", "swiss cheese", "brie", "feta",
        "goat cheese", "string cheese", "cream cheese", "shredded cheese", "provolone",
        "gouda", "ricotta", "sliced cheese",
    ]),
    _c("meat", "Meat & Poultry", ["chicken", "ground beef", "bacon"], [
        "meat", "chicken", "chicken breast", "chicken thigh", "beef", "ground beef",
        "steak", "pork", "pork chop", "bacon", "sausage", "ground turkey", "turkey",
        "lamb", "hot dog", "ham", "ribs", "meatball",
    ]),
    _c("seafood", "Seafood", ["salmon", "shrimp", "fish fillets"], [
        "seafood", "fish", "salmon", "shrimp", "tilapia", "cod", "crab", "lobster",
        "scallop", "tuna steak", "mussel", "clam",
    ]),
    _c("deli", "Deli & Prepared Foods", ["hummus", "sliced turkey", "prepared salads"], [
        "deli", "hummus", "deli meat", "sliced turkey", "salami", "prosciutto",
        "rotisserie chicken", "prepared salad", "sandwich", "sushi", "dip", "guacamole",
        "fresh pasta", "pesto", "lunch meat",
    ]),
    # Pantry
    _c("breakfast", "Cereal & Breakfast", ["cereal", "oatmeal", "maple syrup"], [
        "cereal", "oatmeal", "oat", "rolled oat", "granola", "pancake mix", "waffle mix",
        "pop tart", "breakfast bar", "muesli", "grits", "cream of wheat",
    ]),
    _c("syrups-sweeteners", "Syrups & Sweeteners", ["pancake mix", "honey", "sweeteners"], [
        "syrup", "maple syrup", "pancake syrup", "honey", "agave", "agave nectar",
        "molasses", "sweetener", "stevia", "monk fruit sweetener",
    ]),
    _c("spreads", "Peanut Butter & Spreads", ["jam", "peanut butter", "honey"], [
        "peanut butter", "almond butter", "nut butter", "jam", "jelly", "preserves",
        "nutella", "hazelnut spread", "marmalade", "sunflower butter",
    ]),
    _c("baking", "Baking", ["flour", "sugar", "baking soda"], [
        "flour", "sugar", "brown sugar", "powdered sugar", "baking soda", "baking powder",
        "yeast", "vanilla", "vanilla extract", "chocolate chip", "cake mix",
        "brownie mix", "frosting", "cornstarch", "cocoa powder", "sprinkles",
        "shortening", "condensed milk", "evaporated milk",
    ]),
    _c("spices", "Spices & Seasonings", ["salt", "pepper", "cinnamon"], [
        "spice", "seasoning", "salt", "black pepper", "cinnamon", "paprika", "cumin",
        "oregano", "chili powder", "garlic powder", "onion powder", "bay leaf",
        "nutmeg", "turmeric", "curry powder", "red pepper flake", "everything bagel seasoning",
    ]),
    _c("oils-vinegar", "Oils & Vinegar", ["olive oil", "vinegar", "cooking spray"], [
        "oil", "olive oil", "vegetable oil", "canola oil", "coconut oil", "avocado oil",
        "sesame oil", "cooking spray", "vinegar", "balsamic vinegar", "apple cider vinegar",
    ]),
    _c("condiments", "Condiments & Dressings", ["ketchup", "mustard", "salad dressing"], [
        "condiment", "ketchup", "mustard", "mayo", "mayonnaise", "relish",
        "salad dressing", "ranch", "barbecue sauce", "bbq sauce", "hot sauce", "sriracha",
        "pickle", "olive", "steak sauce", "worcestershire sauce",
    ]),
    _c("pasta-sauce", "Pasta & Sauce", ["spaghetti", "marinara", "mac and cheese"], [
        "pasta", "spaghetti", "penne", "macaroni", "mac and cheese", "noodle", "lasagna",
        "linguine", "fettuccine", "pasta sauce", "marinara", "tomato sauce", "alfredo sauce",
        "ramen", "egg noodle", "orzo",
    ]),
    _c("rice-grains", "Rice, Grains & Beans", ["rice", "quinoa", "dried beans"], [
        "rice", "brown rice", "jasmine rice", "basmati rice", "quinoa", "couscous",
        "lentil", "dried bean", "farro", "barley", "stuffing",
    ]),
    _c("canned-goods", "Canned Goods & Soup", ["soup", "canned beans", "canned tuna"], [
        "canned", "soup", "broth", "stock", "chicken broth", "canned bean", "black bean",
        "chickpea", "kidney bean", "canned tomato", "diced tomato", "tomato paste",
        "canned tuna", "tuna", "canned corn", "canned vegetable", "chili", "canned fruit",
        "coconut milk", "refried bean", "canned chicken", "spam",
    ]),
    _c("international", "International Foods", ["soy sauce", "salsa", "curry sauce"], [
        "soy sauce", "teriyaki", "salsa", "taco shell", "taco seasoning", "curry sauce",
        "curry paste", "fish sauce", "hoisin", "enchilada sauce", "rice noodle",
        "tortilla chip", "seaweed", "miso", "kimchi", "nori",
    ]),
    _c("snacks", "Chips & Snacks", ["chips", "pretzels", "popcorn"], [
        "snack", "chip", "potato chip", "pretzel", "popcorn", "cracker", "rice cake",
        "goldfish", "cheez it", "pita chip", "veggie straw", "granola bar", "protein bar",
        "fruit snack", "beef jerky", "jerky", "puff",
    ]),
    _c("nuts-dried-fruit", "Nuts & Dried Fruit", ["almonds", "trail mix", "raisins"], [
        "nut", "almond", "cashew", "peanut", "pistachio", "walnut", "pecan", "trail mix",
        "dried fruit", "raisin", "dried mango", "date", "dried cranberry", "mixed nut",
        "seed", "sunflower seed", "chia seed",
    ]),
    _c("sweets", "Cookies & Candy", ["cookies", "chocolate", "candy"], [
        "cookie", "candy", "chocolate", "chocolate bar", "dark chocolate", "milk chocolate",
        "gum", "chewing gum", "mint candy", "gummy", "gummy bear", "marshmallow",
        "licorice", "oreo", "biscotti",
    ]),
    _c("coffee-tea", "Coffee & Tea", ["coffee", "tea", "creamer"], [
        "coffee", "ground coffee", "coffee bean", "whole bean coffee", "instant coffee",
        "k cup", "coffee pod", "espresso", "tea", "green tea", "black tea", "herbal tea",
        "chai", "matcha", "coffee creamer", "creamer", "hot chocolate", "cocoa",
    ]),
    _c("beverages", "Drinks", ["soda", "sparkling water", "juice"], [
        "drink", "beverage", "soda", "pop", "cola", "coke", "pepsi", "sprite", "ginger ale",
        "water", "bottled water", "sparkling water", "seltzer", "mineral water",
        "juice", "orange juice", "apple juice", "lemonade", "iced tea", "sports drink",
        "gatorade", "energy drink", "kombucha", "coconut water", "tonic water",
    ]),
    _c("beer-wine", "Beer & Wine", ["beer", "wine", "hard cider"], [
        "beer", "wine", "red wine", "white wine", "rose wine", "champagne", "prosecco",
        "hard cider", "cider", "hard seltzer", "sake", "ale", "lager", "ipa",
    ]),
    _c("frozen", "Frozen Foods", ["frozen vegetables", "frozen meals", "frozen pizza"], [
        "frozen", "frozen vegetable", "frozen fruit", "frozen meal", "frozen dinner",
        "frozen pizza", "frozen waffle", "frozen burrito", "frozen dumpling",
        "frozen shrimp", "tater tot", "french fry", "fish stick", "chicken nugget",
        "frozen berry", "frozen pea", "pot pie", "pizza", "dumpling", "potsticker",
    ]),
    _c("ice-cream", "Ice Cream & Frozen Desserts", ["ice cream", "popsicles", "frozen yogurt"], [
        "ice cream", "gelato", "sorbet", "popsicle", "ice pop", "frozen yogurt",
        "ice cream sandwich", "mochi", "ice",
    ]),
    # Personal care and health
    _c("oral-care", "Oral Care", ["toothbrushes", "mouthwash", "floss"], [
        "toothpaste", "toothbrush", "electric toothbrush", "mouthwash", "floss",
        "dental floss", "whitening strip", "denture",
    ]),
    _c("hair-care", "Hair Care", ["shampoo", "conditioner", "hair gel"], [
        "shampoo", "conditioner", "hair gel", "hair spray", "dry shampoo", "hair dye",
        "hair tie", "brush", "comb", "hair",
    ]),
    _c("body-care", "Bath & Body", ["soap", "body wash", "deodorant"], [
        "soap", "bar soap", "hand soap", "body wash", "deodorant", "antiperspirant",
        "lotion", "body lotion", "razor", "shaving cream", "sunscreen", "lip balm",
        "chapstick", "face wash", "moisturizer", "cotton swab", "q tip", "feminine product",
        "tampon", "pad", "hand sanitizer",
    ]),
    _c("cosmetics", "Beauty & Cosmetics", ["makeup", "nail polish", "makeup remover"], [
        "makeup", "mascara", "lipstick", "foundation", "eyeliner", "nail polish",
        "nail polish remover", "makeup remover", "cotton pad", "concealer", "blush",
    ]),
    _c("otc-medicine", "Medicine & First Aid", ["pain relievers", "cold medicine", "bandages"], [
        "medicine", "pain reliever", "ibuprofen", "advil", "tylenol", "acetaminophen",
        "aspirin", "cold medicine", "cough syrup", "cough drop", "allergy medicine",
        "antacid", "tums", "bandage", "band aid", "first aid", "thermometer", "eye drop",
        "sleep aid", "melatonin", "antibiotic ointment", "neosporin", "nasal spray",
        "pregnancy test", "condom",
    ]),
    _c("vitamins", "Vitamins & Supplements", ["multivitamins", "fish oil", "protein powder"], [
        "vitamin", "multivitamin", "vitamin c", "vitamin d", "fish oil", "supplement",
        "protein powder", "probiotic", "zinc", "magnesium", "electrolyte",
    ]),
    _c("baby", "Baby", ["diapers", "wipes", "baby formula"], [
        "baby", "diaper", "wipe", "baby wipe", "baby formula", "formula", "baby food",
        "pacifier", "baby bottle", "pull up",
    ]),
    # Household
    _c("paper-goods", "Paper Goods", ["toilet paper", "paper towels", "tissues"], [
        "toilet paper", "paper towel", "tissue", "kleenex", "napkin", "paper plate",
        "paper cup", "plastic cup", "plastic utensil",
    ]),
    _c("cleaning", "Cleaning & Laundry", ["laundry detergent", "dish soap", "trash bags"], [
        "cleaning", "cleaner", "laundry detergent", "detergent", "fabric softener",
        "dryer sheet", "bleach", "dish soap", "dishwasher detergent", "dishwasher pod",
        "sponge", "trash bag", "garbage bag", "aluminum foil", "foil", "plastic wrap",
        "zip bag", "ziploc", "sandwich bag", "disinfecting wipe", "all purpose cleaner",
        "glass cleaner", "air freshener", "mop", "broom", "rubber glove", "lysol", "clorox",
    ]),
    _c("pet", "Pet Supplies", ["dog food", "cat litter", "pet treats"], [
        "pet", "dog food", "cat food", "dog treat", "cat treat", "cat litter", "kitty litter",
        "pet food", "dog toy", "cat toy", "leash", "bird seed", "fish food",
    ]),
    _c("batteries-bulbs", "Batteries & Light Bulbs", ["batteries", "light bulbs", "extension cords"], [
        "battery", "aa battery", "aaa battery", "light bulb", "bulb", "led bulb",
        "extension cord", "power strip", "flashlight",
    ]),
    _c("kitchenware", "Kitchen & Home", ["pans", "food storage", "utensils"], [
        "pan", "pot", "frying pan", "skillet", "spatula", "utensil", "knife", "cutting board",
        "food storage container", "tupperware", "mixing bowl", "baking sheet", "mug",
        "plate", "bowl", "glass", "towel", "kitchen towel", "pillow", "sheet", "candle",
    ]),
    _c("electronics", "Electronics", ["phone chargers", "headphones", "cables"], [
        "electronics", "phone charger", "charger", "charging cable", "usb cable",
        "lightning cable", "headphone", "earbud", "speaker", "tv", "television",
        "laptop", "tablet", "video game", "printer ink", "hdmi cable",
    ]),
    _c("office-school", "Office & School", ["pens", "notebooks", "tape"], [
        "pen", "pencil", "notebook", "paper", "printer paper", "tape", "scotch tape",
        "envelope", "marker", "highlighter", "folder", "binder", "glue", "scissors",
        "sticky note", "stapler", "greeting card", "card", "gift wrap", "gift bag",
    ]),
    _c("apparel", "Clothing", ["socks", "t-shirts", "underwear"], [
        "clothing", "sock", "t shirt", "shirt", "underwear", "pajama", "jacket", "hat",
        "glove", "shoe", "sweatshirt",
    ]),
    _c("toys", "Toys & Games", ["toys", "board games", "puzzles"], [
        "toy", "board game", "puzzle", "lego", "doll", "playing card", "balloon",
    ]),
    # Home improvement
    _c("tools", "Tools", ["hammers", "drills", "screwdrivers"], [
        "tool", "hammer", "drill", "screwdriver", "wrench", "pliers", "saw", "tape measure",
        "level", "utility knife", "toolbox", "drill bit", "socket set", "allen key",
        "stud finder", "ladder",
    ]),
    _c("fasteners", "Hardware & Fasteners", ["screws", "nails", "anchors"], [
        "screw", "nail", "bolt", "nut and bolt", "washer", "anchor", "drywall anchor",
        "hinge", "hook", "picture hanging", "zip tie", "bracket", "door knob", "lock",
        "key", "chain", "rope", "bungee cord", "duct tape",
    ]),
    _c("paint", "Paint", ["paint", "brushes", "rollers"], [
        "paint", "primer", "stain", "paint brush", "paint roller", "painter tape",
        "painters tape", "drop cloth", "spray paint", "sandpaper", "wood filler", "caulk",
        "spackle",
    ]),
    _c("plumbing", "Plumbing", ["pipe fittings", "faucets", "plungers"], [
        "plumbing", "pipe", "pvc pipe", "faucet", "plunger", "toilet flapper", "drain cleaner",
        "shower head", "pipe fitting", "teflon tape", "water filter", "garbage disposal",
        "toilet seat", "wax ring",
    ]),
    _c("electrical", "Electrical", ["wire", "outlets", "switches"], [
        "electrical", "wire", "outlet", "light switch", "switch", "outlet cover",
        "electrical tape", "wire nut", "circuit breaker", "dimmer", "junction box",
        "smoke detector", "light fixture",
    ]),
    _c("lumber", "Lumber & Building Materials", ["2x4s", "plywood", "drywall"], [
        "lumber", "wood", "2x4", "plywood", "drywall", "board", "concrete", "cement",
        "insulation", "mdf", "molding", "trim", "brick", "paver", "gravel",
    ]),
    _c("garden", "Garden & Outdoor", ["potting soil", "mulch", "garden hoses"], [
        "garden", "soil", "potting soil", "mulch", "fertilizer", "seed packet", "grass seed",
        "garden hose", "hose", "planter", "shovel", "rake", "weed killer", "plant",
        "lawn mower", "sprinkler", "bird feeder", "grill", "charcoal", "propane",
    ]),
)

CATEGORY_BY_SLUG: dict[str, CategoryDef] = {c.slug: c for c in CATEGORIES}


def _z(name, x, y, categories):
    return ZoneDef(name, x, y, tuple(categories))


# Grocery zones shared by general grocery and supercenter layouts.
_GROCERY_ZONES = (
    _z("Produce", 0.10, 0.20, ["produce-fruit", "produce-veg"]),
    _z("Floral", 0.05, 0.05, ["flowers"]),
    _z("Bakery", 0.20, 0.35, ["bakery"]),
    _z("Deli & Prepared Foods", 0.20, 0.60, ["deli"]),
    _z("Meat & Seafood", 0.45, 0.95, ["meat", "seafood"]),
    _z("Dairy & Eggs", 0.85, 0.90, ["dairy", "eggs", "cheese"]),
    _z("Breakfast & Cereal", 0.40, 0.50, ["breakfast", "syrups-sweeteners", "spreads"]),
    _z("Baking & Spices", 0.45, 0.55, ["baking", "spices", "oils-vinegar"]),
    _z("Pasta, Rice & Canned Goods", 0.50, 0.50,
       ["pasta-sauce", "rice-grains", "canned-goods", "condiments", "international"]),
    _z("Snacks", 0.55, 0.45, ["snacks", "nuts-dried-fruit", "sweets"]),
    _z("Coffee & Tea", 0.35, 0.45, ["coffee-tea"]),
    _z("Beverages", 0.60, 0.45, ["beverages"]),
    _z("Beer & Wine", 0.90, 0.30, ["beer-wine"]),
    _z("Frozen Foods", 0.75, 0.60, ["frozen", "ice-cream"]),
    _z("Health & Beauty", 0.70, 0.25,
       ["oral-care", "hair-care", "body-care", "cosmetics", "otc-medicine", "vitamins"]),
    _z("Baby", 0.75, 0.30, ["baby"]),
    _z("Household & Cleaning", 0.80, 0.40, ["paper-goods", "cleaning", "batteries-bulbs"]),
    _z("Pet", 0.85, 0.45, ["pet"]),
)

LAYOUTS: dict[str, LayoutDef] = {
    "grocery": LayoutDef(
        key="grocery", label="Grocery store",
        entrance=(0.05, 0.0), checkout=(0.50, 0.05),
        zones=_GROCERY_ZONES + (
            _z("Kitchen & Seasonal", 0.90, 0.20, ["kitchenware", "office-school", "toys"]),
        ),
    ),
    "trader_joes": LayoutDef(
        key="trader_joes", label="Trader Joe's",
        entrance=(0.05, 0.0), checkout=(0.55, 0.05),
        zones=(
            _z("Flowers & Produce", 0.10, 0.20, ["flowers", "produce-fruit", "produce-veg"]),
            _z("Bread", 0.25, 0.30, ["bakery"]),
            _z("Snacks, Nuts & Dried Fruit", 0.40, 0.40, ["snacks", "nuts-dried-fruit"]),
            _z("Breakfast/Pantry", 0.50, 0.50, [
                "breakfast", "syrups-sweeteners", "spreads", "baking", "spices",
                "oils-vinegar", "condiments", "pasta-sauce", "rice-grains", "canned-goods",
                "international", "coffee-tea",
            ]),
            _z("Cookies & Candy", 0.60, 0.40, ["sweets"]),
            _z("Beverages", 0.70, 0.50, ["beverages"]),
            _z("Cheese", 0.30, 0.85, ["cheese"]),
            _z("Dairy & Eggs", 0.15, 0.90, ["dairy", "eggs"]),
            _z("Meat & Seafood", 0.50, 0.92, ["meat", "seafood"]),
            _z("Deli & Prepared Foods", 0.70, 0.88, ["deli"]),
            _z("Frozen", 0.88, 0.60, ["frozen", "ice-cream"]),
            _z("Wine & Beer", 0.92, 0.30, ["beer-wine"]),
            _z("Health & Household", 0.85, 0.15, [
                "oral-care", "hair-care", "body-care", "vitamins", "paper-goods", "cleaning",
            ]),
        ),
    ),
    "costco": LayoutDef(
        key="costco", label="Warehouse club",
        entrance=(0.10, 0.0), checkout=(0.60, 0.05),
        zones=(
            _z("Electronics", 0.15, 0.15, ["electronics", "batteries-bulbs"]),
            _z("Seasonal & Home", 0.35, 0.20, ["kitchenware", "toys", "garden"]),
            _z("Clothing & Books", 0.30, 0.35, ["apparel", "office-school"]),
            _z("Health & Beauty", 0.20, 0.45,
               ["oral-care", "hair-care", "body-care", "cosmetics", "otc-medicine", "vitamins"]),
            _z("Hardware & Automotive", 0.10, 0.60, ["tools", "fasteners"]),
            _z("Household & Paper", 0.45, 0.75, ["paper-goods", "cleaning", "baby", "pet"]),
            _z("Snacks & Candy", 0.55, 0.55, ["snacks", "nuts-dried-fruit", "sweets"]),
            _z("Beverages", 0.65, 0.65, ["beverages", "coffee-tea", "beer-wine"]),
            _z("Pantry & Breakfast", 0.60, 0.45, [
                "breakfast", "syrups-sweeteners", "spreads", "baking", "spices",
                "oils-vinegar", "condiments", "pasta-sauce", "rice-grains", "canned-goods",
                "international",
            ]),
            _z("Frozen", 0.80, 0.60, ["frozen", "ice-cream"]),
            _z("Fresh Meat & Seafood", 0.70, 0.95, ["meat", "seafood"]),
            _z("Dairy & Eggs Cooler", 0.90, 0.90, ["dairy", "eggs", "cheese"]),
            _z("Produce Cooler", 0.90, 0.75, ["produce-fruit", "produce-veg", "flowers"]),
            _z("Deli", 0.85, 0.50, ["deli"]),
            _z("Bakery", 0.88, 0.35, ["bakery"]),
        ),
    ),
    "supercenter": LayoutDef(
        key="supercenter", label="Supercenter",
        entrance=(0.05, 0.0), checkout=(0.50, 0.05),
        zones=_GROCERY_ZONES + (
            _z("Electronics", 0.15, 0.80, ["electronics"]),
            _z("Home & Kitchen", 0.25, 0.75, ["kitchenware"]),
            _z("Office & School", 0.30, 0.65, ["office-school"]),
            _z("Clothing", 0.10, 0.50, ["apparel"]),
            _z("Toys", 0.30, 0.90, ["toys"]),
            _z("Hardware & Garden", 0.05, 0.90, ["tools", "fasteners", "garden", "paint"]),
        ),
    ),
    "pharmacy": LayoutDef(
        key="pharmacy", label="Pharmacy",
        entrance=(0.10, 0.0), checkout=(0.30, 0.10),
        zones=(
            _z("Pharmacy & Medicine", 0.80, 0.90, ["otc-medicine", "vitamins"]),
            _z("Personal Care", 0.50, 0.60, ["oral-care", "hair-care", "body-care"]),
            _z("Beauty", 0.30, 0.40, ["cosmetics"]),
            _z("Baby", 0.60, 0.75, ["baby"]),
            _z("Household", 0.70, 0.50, ["paper-goods", "cleaning", "batteries-bulbs", "pet"]),
            _z("Snacks & Candy", 0.25, 0.20, ["snacks", "nuts-dried-fruit", "sweets"]),
            _z("Grocery Basics", 0.45, 0.30,
               ["breakfast", "canned-goods", "pasta-sauce", "coffee-tea", "spreads"]),
            _z("Coolers", 0.90, 0.30, ["beverages", "dairy", "eggs", "ice-cream"]),
            _z("Seasonal & Office", 0.20, 0.60, ["office-school", "toys", "electronics"]),
        ),
    ),
    "home_improvement": LayoutDef(
        key="home_improvement", label="Home improvement",
        entrance=(0.10, 0.0), checkout=(0.50, 0.05),
        zones=(
            _z("Checkout Snacks & Drinks", 0.50, 0.08, ["snacks", "beverages", "sweets"]),
            _z("Tools", 0.30, 0.30, ["tools"]),
            _z("Hardware", 0.40, 0.35, ["fasteners"]),
            _z("Paint", 0.20, 0.50, ["paint"]),
            _z("Electrical & Lighting", 0.50, 0.45, ["electrical", "batteries-bulbs"]),
            _z("Plumbing", 0.60, 0.50, ["plumbing"]),
            _z("Cleaning & Storage", 0.65, 0.30, ["cleaning", "paper-goods"]),
            _z("Kitchen & Bath", 0.75, 0.60, ["kitchenware"]),
            _z("Lumber & Building Materials", 0.40, 0.90, ["lumber"]),
            _z("Garden Center", 0.95, 0.20, ["garden", "flowers"]),
        ),
    ),
}

_RETAILER_LAYOUT_HINTS = (
    ("trader joe", "trader_joes"),
    ("costco", "costco"),
    ("sam's club", "costco"),
    ("bj's", "costco"),
    ("walmart", "supercenter"),
    ("target", "supercenter"),
    ("meijer", "supercenter"),
    ("cvs", "pharmacy"),
    ("walgreens", "pharmacy"),
    ("rite aid", "pharmacy"),
    ("home depot", "home_improvement"),
    ("lowe", "home_improvement"),
    ("ace hardware", "home_improvement"),
)


def layout_for_retailer(retailer_name: str | None) -> LayoutDef:
    name = (retailer_name or "").lower()
    for hint, key in _RETAILER_LAYOUT_HINTS:
        if hint in name:
            return LAYOUTS[key]
    return LAYOUTS["grocery"]
