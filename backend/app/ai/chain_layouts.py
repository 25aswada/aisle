"""Chain-specific layouts, researched from public descriptions of each chain's usual
store pattern (retailer pages, news and retail-analysis articles, shopper write-ups).

Individual store floor plans aren't public, so these describe where a chain *usually*
puts each department, redrawn in our own normalized units: x 0 (left wall) to 1 (right
wall) facing into the store from the entrance, y 0 (front, where the entrance and
checkouts are) to 1 (back wall). Real stores vary (left vs right entrances, remodels,
state alcohol laws), so the app always labels these as a typical layout. Sources and
caveats are kept next to each layout; placements marked "inferred" weren't directly
documented.
"""
from __future__ import annotations

from .catalog import LayoutDef, ZoneDef


def _z(name, x, y, categories):
    return ZoneDef(name, x, y, tuple(categories))


_PANTRY = (
    "breakfast", "syrups-sweeteners", "spreads", "baking", "spices", "oils-vinegar",
    "condiments", "pasta-sauce", "rice-grains", "canned-goods", "international",
)
_HEALTH_BEAUTY = ("oral-care", "hair-care", "body-care", "cosmetics", "otc-medicine", "vitamins")


CHAIN_LAYOUTS: dict[str, LayoutDef] = {
    # Costco's "racetrack": enter past electronics, fresh foods along the back wall, then
    # back up past frozen, packaged grocery and drinks to health & beauty by checkout.
    # Sources: theproducenews.com/headlines/costco-shopping-experience;
    # fastcompany.com/3025312 (Costco design). Caveats: entrance side varies by
    # warehouse; order along the back wall and floral placement are inferred.
    "costco": LayoutDef(
        key="costco", label="Costco",
        entrance=(0.82, 0.05), checkout=(0.35, 0.05),
        zones=(
            _z("Electronics", 0.80, 0.20, ["electronics", "batteries-bulbs"]),
            _z("Clothing & Books", 0.58, 0.28, ["apparel", "office-school"]),
            _z("Toys & Seasonal", 0.50, 0.45, ["toys", "garden"]),
            _z("Home & Hardware", 0.82, 0.50, ["kitchenware", "tools", "fasteners"]),
            _z("Produce Cooler", 0.78, 0.88, ["produce-fruit", "produce-veg"]),
            _z("Meat & Seafood", 0.58, 0.92, ["meat", "seafood"]),
            _z("Deli & Dairy", 0.38, 0.90, ["deli", "cheese", "dairy", "eggs"]),
            _z("Bakery & Floral", 0.22, 0.85, ["bakery", "flowers"]),
            _z("Paper & Household", 0.08, 0.80, ["paper-goods", "cleaning", "pet", "baby"]),
            _z("Frozen Foods", 0.10, 0.55, ["frozen", "ice-cream"]),
            _z("Pantry Grocery", 0.30, 0.50, _PANTRY),
            _z("Snacks & Candy", 0.30, 0.30, ["snacks", "nuts-dried-fruit", "sweets"]),
            _z("Beverages & Coffee", 0.12, 0.30, ["beverages", "coffee-tea", "beer-wine"]),
            _z("Health & Beauty", 0.22, 0.14, _HEALTH_BEAUTY),
        ),
    ),
    # Sources: en.wikipedia.org/wiki/Sam's_Club (departments); flickr.com photo notes
    # (service departments facing the coolers, walk-in produce cooler);
    # zero-zone.com membership-club case study; grocerydive.com Grapevine TX club.
    # Caveats: least documented; electronics at the front, the infield and front
    # health & beauty are inferred from the warehouse-club pattern.
    "sams_club": LayoutDef(
        key="sams_club", label="Sam's Club",
        entrance=(0.75, 0.05), checkout=(0.40, 0.05),
        zones=(
            _z("TV & Electronics", 0.78, 0.20, ["electronics"]),
            _z("Tire & Battery", 0.92, 0.12, ["batteries-bulbs"]),
            _z("Apparel & Books", 0.58, 0.28, ["apparel", "office-school"]),
            _z("Seasonal & Toys", 0.50, 0.48, ["toys", "garden"]),
            _z("Home & Hardware", 0.85, 0.50, ["kitchenware", "tools", "fasteners"]),
            _z("Produce Cooler", 0.78, 0.90, ["produce-fruit", "produce-veg"]),
            _z("Meat & Seafood", 0.58, 0.92, ["meat", "seafood"]),
            _z("Deli & Cheese", 0.42, 0.86, ["deli", "cheese"]),
            _z("Bakery & Floral", 0.25, 0.88, ["bakery", "flowers"]),
            _z("Dairy & Eggs", 0.10, 0.82, ["dairy", "eggs"]),
            _z("Freezers", 0.10, 0.60, ["frozen", "ice-cream"]),
            _z("Pantry Grocery", 0.30, 0.52, _PANTRY),
            _z("Snacks & Beverages", 0.25, 0.32,
               ["snacks", "nuts-dried-fruit", "sweets", "beverages", "coffee-tea", "beer-wine"]),
            _z("Paper & Cleaning", 0.08, 0.38, ["paper-goods", "cleaning", "pet", "baby"]),
            _z("Health & Pharmacy", 0.20, 0.14, _HEALTH_BEAUTY),
        ),
    ),
    # Flowers at the door, produce down the right, meat/cheese/dairy along the back,
    # open frozen cases through the middle (condiments shelved above them).
    # Sources: apartmenttherapy.com (floral by the doors); chrisniesen.substack.com;
    # medium.com/@projectux (route, milk at the back); marketreportblog.com Westfield NJ
    # tour; bustle.com and tastingtable.com (frozen cases, condiments above).
    # Caveats: Trader Joe's says layouts vary; many stores are reused buildings.
    "trader_joes": LayoutDef(
        key="trader_joes", label="Trader Joe's",
        entrance=(0.82, 0.05), checkout=(0.40, 0.06),
        zones=(
            _z("Flowers", 0.85, 0.13, ["flowers"]),
            _z("Produce", 0.85, 0.40, ["produce-fruit", "produce-veg"]),
            _z("Bread & Bakery", 0.82, 0.68, ["bakery"]),
            _z("Meat & Seafood", 0.62, 0.90, ["meat", "seafood"]),
            _z("Cheese & Deli", 0.42, 0.90, ["cheese", "deli"]),
            _z("Dairy & Eggs", 0.20, 0.88, ["dairy", "eggs"]),
            _z("Frozen Foods", 0.55, 0.55, ["frozen", "ice-cream", "condiments"]),
            _z("Pantry Aisles", 0.38, 0.42,
               [slug for slug in _PANTRY if slug != "condiments"]),
            _z("Snacks & Nuts", 0.22, 0.35, ["snacks", "nuts-dried-fruit", "sweets"]),
            _z("Coffee & Drinks", 0.15, 0.55, ["coffee-tea", "beverages"]),
            _z("Wine & Beer", 0.15, 0.15, ["beer-wine"]),
            _z("Health & Household", 0.08, 0.70,
               ["oral-care", "hair-care", "body-care", "vitamins", "paper-goods", "cleaning", "pet"]),
        ),
    ),
    # Newer "fresh-forward" US format: produce first, bakery and meat along the back,
    # Aldi Finds in the middle, dairy and frozen in the last aisle before checkout.
    # Sources: grocerydive.com (new model leads with produce, in-store bakery);
    # supermarketnews.com (fresh-forward layout); thenewdaily.com.au (traditional
    # layout, Special Buys in the middle, frozen/dairy last); aol.com (staples at the
    # back); gimmesomeoven.com (few long aisles). Caveats: unremodeled stores start
    # with pantry or snacks; order within the long middle aisles is inferred.
    "aldi": LayoutDef(
        key="aldi", label="Aldi",
        entrance=(0.85, 0.05), checkout=(0.35, 0.05),
        zones=(
            _z("Produce & Flowers", 0.85, 0.35, ["produce-fruit", "produce-veg", "flowers"]),
            _z("Bakery & Bread", 0.75, 0.70, ["bakery"]),
            _z("Meat & Seafood", 0.60, 0.92, ["meat", "seafood"]),
            _z("Pantry Aisle", 0.62, 0.45, _PANTRY),
            _z("Snacks & Coffee", 0.50, 0.30, ["snacks", "nuts-dried-fruit", "sweets", "coffee-tea"]),
            _z("Beverages & Alcohol", 0.48, 0.70, ["beverages", "beer-wine"]),
            _z("Aldi Finds", 0.38, 0.50,
               ["kitchenware", "electronics", "apparel", "toys", "tools", "garden", "office-school"]),
            _z("Household & Pet", 0.28, 0.75, ["paper-goods", "cleaning", "pet", "batteries-bulbs"]),
            _z("Health & Baby", 0.28, 0.30, list(_HEALTH_BEAUTY) + ["baby"]),
            _z("Dairy & Deli", 0.10, 0.75, ["dairy", "eggs", "cheese", "deli"]),
            _z("Frozen Foods", 0.10, 0.40, ["frozen", "ice-cream"]),
        ),
    ),
    # Grocery side: produce first, fresh perimeter, dairy at the back; pharmacy between
    # the sides; general merchandise with electronics and toys at the back, garden at
    # the far end. Sources: grocerydive.com reimagined supercenter; 247wallst.com map of
    # Walmart layouts; corporate.walmart.com 2020 store design; blog.founders.illinois.edu
    # Walmart aisle map. Caveats: two entrances (general-merchandise door ~x 0.75 not
    # shown); grocery side can be left or right; hardware/pets/baby/office inferred.
    "walmart": LayoutDef(
        key="walmart", label="Walmart",
        entrance=(0.25, 0.02), checkout=(0.50, 0.08),
        zones=(
            _z("Produce", 0.12, 0.20, ["produce-fruit", "produce-veg", "flowers"]),
            _z("Bakery", 0.07, 0.42, ["bakery"]),
            _z("Deli", 0.07, 0.65, ["deli"]),
            _z("Meat & Seafood", 0.15, 0.92, ["meat", "seafood"]),
            _z("Dairy", 0.35, 0.92, ["dairy", "eggs", "cheese"]),
            _z("Frozen", 0.38, 0.70, ["frozen", "ice-cream"]),
            _z("Pantry", 0.24, 0.52, _PANTRY + ("coffee-tea",)),
            _z("Snacks & Drinks", 0.30, 0.30,
               ["snacks", "nuts-dried-fruit", "sweets", "beverages", "beer-wine"]),
            _z("Pharmacy", 0.50, 0.18, ["otc-medicine", "vitamins"]),
            _z("Health & Beauty", 0.50, 0.40, ["oral-care", "hair-care", "body-care", "cosmetics"]),
            _z("Household", 0.45, 0.65, ["paper-goods", "cleaning"]),
            _z("Pets", 0.50, 0.85, ["pet"]),
            _z("Baby", 0.60, 0.62, ["baby"]),
            _z("Apparel", 0.72, 0.30, ["apparel"]),
            _z("Home & Kitchen", 0.74, 0.60, ["kitchenware"]),
            _z("Electronics & Office", 0.62, 0.90, ["electronics", "office-school"]),
            _z("Toys", 0.80, 0.90, ["toys"]),
            _z("Hardware & Paint", 0.90, 0.65,
               ["tools", "fasteners", "paint", "plumbing", "electrical", "batteries-bulbs"]),
            _z("Garden Center", 0.92, 0.18, ["garden"]),
        ),
    ),
    # Starbucks and the Dollar Spot by the door (landmarks, not modelled); grocery along
    # one side; beauty across the main aisle; general merchandise on the other side with
    # electronics and toys at the back. Sources: thedailymeal.com Target layout;
    # gobankingrates.com (Dollar Spot); saira-tabassum.medium.com Home Depot vs Target;
    # heathracela.substack.com (Ulta shop at the front). Caveats: grocery can be on
    # either side; small formats have little fresh food; several spots inferred.
    "target": LayoutDef(
        key="target", label="Target",
        entrance=(0.45, 0.02), checkout=(0.55, 0.08),
        zones=(
            _z("Produce & Flowers", 0.08, 0.25, ["produce-fruit", "produce-veg", "flowers"]),
            _z("Bakery", 0.08, 0.42, ["bakery"]),
            _z("Meat & Deli", 0.08, 0.65, ["meat", "seafood", "deli"]),
            _z("Dairy & Eggs", 0.15, 0.90, ["dairy", "eggs", "cheese"]),
            _z("Frozen", 0.28, 0.72, ["frozen", "ice-cream"]),
            _z("Pantry", 0.22, 0.48, _PANTRY + ("coffee-tea",)),
            _z("Snacks & Drinks", 0.32, 0.28,
               ["snacks", "nuts-dried-fruit", "sweets", "beverages", "beer-wine"]),
            _z("Beauty", 0.55, 0.24, ["cosmetics", "hair-care", "body-care"]),
            _z("Health & Pharmacy", 0.42, 0.50, ["otc-medicine", "vitamins", "oral-care"]),
            _z("Baby", 0.50, 0.66, ["baby"]),
            _z("Household Essentials", 0.40, 0.86, ["paper-goods", "cleaning"]),
            _z("Pets", 0.28, 0.92, ["pet"]),
            _z("Apparel", 0.75, 0.28, ["apparel"]),
            _z("Home & Kitchen", 0.85, 0.58, ["kitchenware"]),
            _z("School & Office", 0.68, 0.66, ["office-school"]),
            _z("Electronics", 0.60, 0.90, ["electronics", "batteries-bulbs"]),
            _z("Toys", 0.78, 0.90, ["toys"]),
            _z("Home Improvement", 0.92, 0.82, ["tools", "fasteners", "electrical"]),
            _z("Seasonal & Patio", 0.90, 0.16, ["garden"]),
        ),
    ),
    # Produce and prepared foods at the front, meat and seafood counters along the back,
    # Whole Body (supplements, body care) by the registers. Sources: coohom.com Whole
    # Foods layout; goodrx.com grocery layouts; supermarketnews.com 365 floor plan;
    # gliserland.com department guide. Caveats: varies most of the chains (urban,
    # multi-level, Daily Shop); left/right placements are estimates.
    "whole_foods": LayoutDef(
        key="whole_foods", label="Whole Foods",
        entrance=(0.30, 0.02), checkout=(0.55, 0.08),
        zones=(
            _z("Flowers", 0.10, 0.08, ["flowers"]),
            _z("Produce", 0.15, 0.30, ["produce-fruit", "produce-veg"]),
            _z("Prepared Foods", 0.48, 0.28, ["deli"]),
            _z("Bakery", 0.68, 0.32, ["bakery"]),
            _z("Specialty Cheese", 0.12, 0.60, ["cheese"]),
            _z("Meat", 0.38, 0.92, ["meat"]),
            _z("Seafood", 0.60, 0.92, ["seafood"]),
            _z("Dairy & Eggs", 0.88, 0.86, ["dairy", "eggs"]),
            _z("Frozen", 0.70, 0.66, ["frozen", "ice-cream"]),
            _z("Grocery", 0.42, 0.62, _PANTRY + ("coffee-tea",)),
            _z("Bulk", 0.24, 0.78, ["nuts-dried-fruit"]),
            _z("Snacks & Beverages", 0.56, 0.50, ["snacks", "sweets", "beverages"]),
            _z("Beer & Wine", 0.90, 0.55, ["beer-wine"]),
            _z("Household & Baby", 0.76, 0.46, ["paper-goods", "cleaning", "baby", "pet"]),
            _z("Whole Body", 0.86, 0.20, _HEALTH_BEAUTY),
        ),
    ),
    # "Power alley" of deli, bakery and produce from the door along the left wall,
    # meat and dairy across the back, pharmacy in the front-right corner. Sources:
    # houstonhistoricretail.com Kroger power alley; teachengineering.org public
    # evacuation map of a Huber Heights, OH Kroger (relative positions only);
    # groceteria.ca layout history. Caveats: leans on one store; many are mirrored.
    "kroger": LayoutDef(
        key="kroger", label="Kroger",
        entrance=(0.45, 0.02), checkout=(0.62, 0.10),
        zones=(
            _z("Floral", 0.25, 0.10, ["flowers"]),
            _z("Deli", 0.08, 0.12, ["deli"]),
            _z("Bakery", 0.07, 0.38, ["bakery"]),
            _z("Produce", 0.14, 0.68, ["produce-fruit", "produce-veg"]),
            _z("Nature's Market", 0.32, 0.88, ["nuts-dried-fruit"]),
            _z("Meat & Seafood", 0.55, 0.90, ["meat", "seafood"]),
            _z("Dairy", 0.88, 0.88, ["dairy", "eggs", "cheese"]),
            _z("Frozen", 0.66, 0.55, ["frozen", "ice-cream"]),
            _z("Beverages & Wine", 0.87, 0.55, ["beverages", "beer-wine"]),
            _z("Grocery", 0.30, 0.50, _PANTRY + ("coffee-tea",)),
            _z("Snacks & Candy", 0.46, 0.48, ["snacks", "sweets"]),
            _z("General Merchandise", 0.50, 0.68, ["kitchenware", "batteries-bulbs", "office-school"]),
            _z("Household & Pet", 0.52, 0.32, ["paper-goods", "cleaning", "pet"]),
            _z("Baby", 0.70, 0.30, ["baby"]),
            _z("Health & Beauty", 0.78, 0.22, ["oral-care", "hair-care", "body-care", "cosmetics"]),
            _z("Pharmacy", 0.92, 0.26, ["otc-medicine", "vitamins"]),
        ),
    ),
    # Beauty and impulse items at the front, pharmacy at the back so shoppers pass the
    # aisles. Sources: cnn.com 2025 CVS small stores; pbahealth.com retail pharmacy
    # layouts; prnewswire.com and drugstorenews.com CVS store design. Caveats: only
    # front beauty/snacks and back pharmacy are well supported; the rest is inferred.
    "cvs": LayoutDef(
        key="cvs", label="CVS",
        entrance=(0.50, 0.03), checkout=(0.70, 0.10),
        zones=(
            _z("Beauty & Cosmetics", 0.25, 0.18, ["cosmetics"]),
            _z("Snacks & Candy", 0.65, 0.22, ["snacks", "sweets", "nuts-dried-fruit"]),
            _z("Cards & Seasonal", 0.85, 0.30, ["toys", "office-school", "flowers"]),
            _z("Hair Care", 0.12, 0.42, ["hair-care"]),
            _z("Skin & Personal Care", 0.25, 0.55, ["body-care"]),
            _z("Oral Care", 0.38, 0.62, ["oral-care"]),
            _z("Electronics & Photo", 0.85, 0.48, ["electronics", "batteries-bulbs"]),
            _z("Grocery", 0.68, 0.58,
               ["breakfast", "coffee-tea", "canned-goods", "pasta-sauce", "spreads", "condiments"]),
            _z("Coolers & Frozen", 0.93, 0.78,
               ["beverages", "dairy", "eggs", "frozen", "ice-cream", "beer-wine"]),
            _z("Household & Pet", 0.68, 0.80, ["cleaning", "paper-goods", "pet", "kitchenware"]),
            _z("Baby & Family", 0.25, 0.78, ["baby"]),
            _z("Vitamins", 0.70, 0.92, ["vitamins"]),
            _z("Pharmacy & Cold/Flu", 0.45, 0.92, ["otc-medicine"]),
        ),
    ),
    # Same drugstore pattern; pharmacy in a back corner (often by the drive-thru).
    # Sources: corporate.walgreens.com ("traditional place at the back of the store");
    # coohom.com Walgreens layout; pbahealth.com pharmacy layouts. Caveats: corner
    # side varies with the drive-thru; most placements inferred.
    "walgreens": LayoutDef(
        key="walgreens", label="Walgreens",
        entrance=(0.40, 0.03), checkout=(0.55, 0.10),
        zones=(
            _z("Beauty", 0.18, 0.18, ["cosmetics"]),
            _z("Seasonal & Cards", 0.75, 0.18, ["toys", "office-school", "flowers"]),
            _z("Snacks & Candy", 0.50, 0.25, ["snacks", "sweets", "nuts-dried-fruit"]),
            _z("Hair Care", 0.12, 0.45, ["hair-care"]),
            _z("Personal Care", 0.25, 0.58, ["body-care", "oral-care"]),
            _z("Photo & Electronics", 0.85, 0.40, ["electronics", "batteries-bulbs"]),
            _z("Grocery", 0.62, 0.55,
               ["breakfast", "coffee-tea", "canned-goods", "pasta-sauce", "spreads", "condiments"]),
            _z("Household & Pet", 0.80, 0.68, ["cleaning", "paper-goods", "pet", "kitchenware"]),
            _z("Coolers & Frozen", 0.93, 0.85,
               ["beverages", "dairy", "eggs", "frozen", "ice-cream", "beer-wine"]),
            _z("Baby", 0.30, 0.80, ["baby"]),
            _z("Vitamins", 0.50, 0.85, ["vitamins"]),
            _z("Pharmacy & Health", 0.20, 0.92, ["otc-medicine"]),
        ),
    ),
    # Garden center at one end, lumber at the other, trades in between, paint central.
    # Sources: coohom.com Home Depot layout; quora.com (lumber one side, garden the
    # other); saira-tabassum.medium.com (electrical on the left, lumber far right);
    # homedepot.com store pages (attached garden centers). Caveats: often mirrored.
    "home_depot": LayoutDef(
        key="home_depot", label="Home Depot",
        entrance=(0.45, 0.03), checkout=(0.45, 0.10),
        zones=(
            _z("Garden Center", 0.07, 0.30, ["garden", "flowers"]),
            _z("Electrical & Lighting", 0.22, 0.55, ["electrical", "batteries-bulbs", "electronics"]),
            _z("Plumbing", 0.35, 0.75, ["plumbing"]),
            _z("Paint", 0.45, 0.35, ["paint"]),
            _z("Cleaning & Storage", 0.55, 0.60, ["cleaning", "paper-goods"]),
            _z("Tools", 0.70, 0.35, ["tools"]),
            _z("Hardware", 0.70, 0.65, ["fasteners"]),
            _z("Lumber & Building", 0.92, 0.70, ["lumber"]),
            _z("Checkout Snacks", 0.60, 0.08, ["snacks", "sweets", "beverages"]),
        ),
    ),
    # Same big-box pattern. Sources: corporate.lowes.com 2004 annual report (prototype
    # sizes, attached garden centers); lowes.com store pages (department list);
    # coohom.com Lowe's layout. Caveats: weakest-sourced; interior positions inferred.
    "lowes": LayoutDef(
        key="lowes", label="Lowe's",
        entrance=(0.50, 0.03), checkout=(0.50, 0.10),
        zones=(
            _z("Garden Center", 0.07, 0.30, ["garden", "flowers"]),
            _z("Appliances", 0.30, 0.20, ["kitchenware"]),
            _z("Paint", 0.50, 0.40, ["paint"]),
            _z("Lighting & Fans", 0.22, 0.55, ["batteries-bulbs", "electronics"]),
            _z("Electrical", 0.30, 0.72, ["electrical"]),
            _z("Plumbing", 0.45, 0.80, ["plumbing"]),
            _z("Cleaning", 0.55, 0.62, ["cleaning", "paper-goods"]),
            _z("Tools", 0.70, 0.35, ["tools"]),
            _z("Hardware", 0.70, 0.65, ["fasteners"]),
            _z("Lumber & Building", 0.92, 0.70, ["lumber"]),
            _z("Checkout Snacks", 0.62, 0.08, ["snacks", "sweets", "beverages"]),
        ),
    ),
}

# Retailer-name hints for the chains above, checked before the generic store formats.
CHAIN_HINTS: tuple[tuple[str, str], ...] = (
    ("costco", "costco"),
    ("sam's club", "sams_club"),
    ("sams club", "sams_club"),
    ("trader joe", "trader_joes"),
    ("aldi", "aldi"),
    ("walmart", "walmart"),
    ("target", "target"),
    ("whole foods", "whole_foods"),
    ("kroger", "kroger"),
    ("cvs", "cvs"),
    ("walgreens", "walgreens"),
    ("home depot", "home_depot"),
    ("lowe's", "lowes"),
    ("lowes", "lowes"),
)
