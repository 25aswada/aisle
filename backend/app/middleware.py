"""Checks every request before it reaches a route: notes the caller's IP for limits deep
in the code (limits.request_ip), refuses oversized bodies before they're read into memory,
turns away signed-out photos before reading them, and on Heroku sends plain-HTTP requests
to HTTPS. Also adds browser security headers to every response."""
from __future__ import annotations

import json

from .limits import request_ip
from .schemas import MAX_CHAT_PHOTOS, MAX_PHOTO_BASE64

# Requests are small JSON; the largest (sharing a list of 500 items) stays well under this.
MAX_BODY_BYTES = 256 * 1024
# Routes that take a photo, and what they're called in "Sign in to use …". They need an
# account, so only requests with a session token get the photo-sized limit: room for a
# chat's couple of photos at their largest (the app sends one, about 1024 px).
PHOTO_ROUTES = {"/chat": "follow-ups", "/identify": "photo search", "/lists/scan": "list scanning"}
MAX_PHOTO_BODY_BYTES = MAX_CHAT_PHOTOS * MAX_PHOTO_BASE64 + MAX_BODY_BYTES


def has_bearer_token(headers: dict) -> bool:
    """Whether the request carries a session token at all. Routes still check it's real."""
    scheme, _, token = headers.get(b"authorization", b"").decode("latin-1").partition(" ")
    return scheme.lower() == "bearer" and bool(token.strip())


class RequestGuard:
    def __init__(self, app, *, redirect_http: bool = False, max_body: int = MAX_BODY_BYTES,
                 max_photo_body: int = MAX_PHOTO_BODY_BYTES):
        self.app = app
        self.redirect_http = redirect_http
        self.max_body = max_body
        self.max_photo_body = max_photo_body

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        headers = {key.lower(): value for key, value in scope.get("headers", [])}

        forwarded = headers.get(b"x-forwarded-for", b"").decode("latin-1")
        # Heroku's router appends the address it saw; earlier entries came from the client.
        ip = forwarded.split(",")[-1].strip() if forwarded else (scope.get("client") or (None,))[0]
        token = request_ip.set(ip or None)
        try:
            if self.redirect_http and headers.get(b"x-forwarded-proto") == b"http":
                host = headers.get(b"host", b"").decode("latin-1")
                query = scope.get("query_string", b"").decode("latin-1")
                location = f"https://{host}{scope['path']}" + (f"?{query}" if query else "")
                return await self._respond(send, 308, {"detail": "Use HTTPS."}, [(b"location", location.encode())])

            photo = PHOTO_ROUTES.get(scope["path"]) if scope.get("method") == "POST" else None
            if photo and not has_bearer_token(headers):
                # The route would say the same, but only after reading and decoding the photo.
                return await self._respond(send, 401, {"detail": f"Sign in to use {photo}."})
            max_body = self.max_photo_body if photo else self.max_body

            length = headers.get(b"content-length")
            if length is not None and length.isdigit() and int(length) > max_body:
                return await self._respond(send, 413, {"detail": "That request is too large."})

            received = 0

            async def limited_receive():
                nonlocal received
                message = await receive()
                if message["type"] == "http.request":
                    received += len(message.get("body", b""))
                    if received > max_body:
                        # A body without a Content-Length that keeps going: stop reading it.
                        return {"type": "http.disconnect"}
                return message

            await self.app(scope, limited_receive, send)
        finally:
            request_ip.reset(token)

    @staticmethod
    async def _respond(send, status: int, body: dict, extra_headers: list | None = None) -> None:
        payload = json.dumps(body).encode()
        await send({"type": "http.response.start", "status": status, "headers": [
            (b"content-type", b"application/json"), (b"content-length", str(len(payload)).encode()),
            *(extra_headers or []),
        ]})
        await send({"type": "http.response.body", "body": payload})


# On every response, JSON and the HTML pages (/privacy, /terms, /support) alike: no
# guessing content types, no referrer for other sites, and never shown inside a frame.
SECURITY_HEADERS = [
    (b"x-content-type-options", b"nosniff"),
    (b"referrer-policy", b"no-referrer"),
    (b"content-security-policy", b"frame-ancestors 'none'"),
    (b"x-frame-options", b"DENY"),
]
# Browsers then only use HTTPS for a year. Only on Heroku, which serves the API over HTTPS.
HSTS = (b"strict-transport-security", b"max-age=31536000; includeSubDomains")


class SecurityHeaders:
    def __init__(self, app, *, hsts: bool = False):
        self.app = app
        self.headers = SECURITY_HEADERS + ([HSTS] if hsts else [])

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                message = {**message, "headers": [*message.get("headers", []), *self.headers]}
            await send(message)

        await self.app(scope, receive, send_with_headers)
