"""Logs and error reports.

Logs go to stdout, where Heroku collects them, as `LEVEL logger: message` (Heroku adds
the time). Log lines never carry emails, phone numbers, codes or tokens.

Errors go to Sentry when SENTRY_DSN is set, and nowhere otherwise (local development,
tests). Reports carry the error and where it happened, but no request bodies (sign-in
codes, emails, phone numbers, photos), no query strings (locations), no headers that
could identify someone (tokens, IP addresses), no local variables and no user.
"""
from __future__ import annotations

import logging
import sys

from .config import Settings

FORMAT = "%(levelname)s %(name)s: %(message)s"
# Request headers worth keeping on an error report: none of them identify anyone.
SAFE_HEADERS = {"accept", "content-length", "content-type", "user-agent"}


def configure_logging(settings: Settings) -> None:
    """Sends the app's logs to stdout at the configured level (INFO unless set)."""
    level = logging.getLevelName(settings.aisle_log_level.strip().upper())
    root = logging.getLogger()
    root.setLevel(level if isinstance(level, int) else logging.INFO)
    if not any(getattr(handler, "_aisle", False) for handler in root.handlers):
        handler = logging.StreamHandler(sys.stdout)
        handler.setFormatter(logging.Formatter(FORMAT))
        handler._aisle = True  # So reloading the app doesn't add a second one.
        root.addHandler(handler)
    # httpx logs every outgoing request's URL at INFO; URLs can carry keys and tokens.
    for noisy in ("httpx", "httpcore"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


def scrub_event(event: dict, hint: dict | None = None) -> dict:
    """An error report with nothing personal left in it."""
    request = event.get("request")
    if isinstance(request, dict):
        for key in ("data", "cookies", "query_string", "env"):
            request.pop(key, None)
        if isinstance(request.get("url"), str):
            request["url"] = request["url"].split("?", 1)[0]
        headers = request.get("headers")
        if isinstance(headers, dict):
            request["headers"] = {k: v for k, v in headers.items() if k.lower() in SAFE_HEADERS}
    event.pop("user", None)
    return event


def scrub_breadcrumb(crumb: dict, hint: dict | None = None) -> dict:
    """Outgoing request breadcrumbs keep the address but not its query string."""
    data = crumb.get("data")
    if isinstance(data, dict):
        for key in ("http.query", "http.fragment"):
            data.pop(key, None)
        if isinstance(data.get("url"), str):
            data["url"] = data["url"].split("?", 1)[0]
    return crumb


def init_sentry(settings: Settings) -> bool:
    """Starts error reporting when a DSN is set. Returns whether it did."""
    if not settings.sentry_dsn:
        return False
    import sentry_sdk  # Imported only when used.

    sentry_sdk.init(
        dsn=settings.sentry_dsn,
        environment=settings.sentry_environment or ("production" if settings.on_heroku else "development"),
        traces_sample_rate=settings.sentry_traces_sample_rate,
        send_default_pii=False,
        include_local_variables=False,
        max_request_body_size="never",
        before_send=scrub_event,
        before_breadcrumb=scrub_breadcrumb,
    )
    return True
