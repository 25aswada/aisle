"""Checks every request before it reaches a route: notes the caller's IP for limits deep
in the code (limits.request_ip), refuses oversized bodies before they're read into memory,
and on Heroku sends plain-HTTP requests to HTTPS."""
from __future__ import annotations

import json

from .limits import request_ip

# The largest legitimate request is a chat with a couple of photos (each at most 4 MB of
# base64, and the app sends them much smaller).
MAX_BODY_BYTES = 8 * 1024 * 1024


class RequestGuard:
    def __init__(self, app, *, redirect_http: bool = False, max_body: int = MAX_BODY_BYTES):
        self.app = app
        self.redirect_http = redirect_http
        self.max_body = max_body

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

            length = headers.get(b"content-length")
            if length is not None and length.isdigit() and int(length) > self.max_body:
                return await self._respond(send, 413, {"detail": "That request is too large."})

            received = 0

            async def limited_receive():
                nonlocal received
                message = await receive()
                if message["type"] == "http.request":
                    received += len(message.get("body", b""))
                    if received > self.max_body:
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
