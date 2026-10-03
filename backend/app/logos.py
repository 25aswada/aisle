"""Retailer logo URLs from logo.dev. Without a key, no logo URLs are returned."""
from urllib.parse import quote, urlencode

from .config import get_settings

LOGO_SIZE = 128


def logo_url(domain: str | None) -> str | None:
    """Image URL for a retailer's domain, or None when there's no domain or no key.

    Uses the publishable (pk_) key, which logo.dev documents as safe in client code.
    `fallback=404` makes unknown domains fail so the app shows its letter tile
    instead of a generated monogram.
    """
    key = get_settings().logo_dev_publishable_key
    if not domain or not key:
        return None
    query = urlencode({"token": key, "size": LOGO_SIZE, "format": "png", "retina": "true", "fallback": "404"})
    return f"https://img.logo.dev/{quote(domain.strip().lower())}?{query}"
