import pytest

from backend.app.ai.catalog import CATEGORY_BY_SLUG, LAYOUTS, layout_for_retailer


@pytest.mark.parametrize("key", sorted(LAYOUTS))
def test_layout_is_consistent(key):
    layout = LAYOUTS[key]
    for x, y in (layout.entrance, layout.checkout):
        assert 0 <= x <= 1 and 0 <= y <= 1
    names = [zone.name for zone in layout.zones]
    assert len(names) == len(set(names)), "department names must be unique"
    seen: dict[str, str] = {}
    for zone in layout.zones:
        assert 0 < len(zone.name) <= 28, zone.name
        assert 0 <= zone.x <= 1 and 0 <= zone.y <= 1, zone.name
        assert zone.categories, f"{zone.name} holds nothing"
        for slug in zone.categories:
            assert slug in CATEGORY_BY_SLUG, f"unknown category {slug!r} in {zone.name}"
            assert slug not in seen, f"{slug} is in both {seen[slug]} and {zone.name}"
            seen[slug] = zone.name
