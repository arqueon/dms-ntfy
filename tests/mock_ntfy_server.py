#!/usr/bin/env python3
"""Tiny local ntfy-compatible poll endpoint for live DMS UI verification."""

import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


NOW = int(time.time())
MESSAGES = [
    {
        "id": "demo3-system",
        "time": NOW,
        "event": "message",
        "topic": "sistema",
        "title": "Service restored",
        "message": "The local ntfy mock is healthy again.",
        "priority": 4,
        "tags": ["white_check_mark", "server"],
        "click": "https://docs.ntfy.sh/",
    },
    {
        "id": "demo3-mail",
        "time": NOW - 70,
        "event": "message",
        "topic": "correos",
        "title": "Message needs review",
        "message": "Open the related task when you are ready to process it.",
        "priority": 5,
        "tags": ["email", "warning"],
        "actions": [
            {
                "action": "view",
                "label": "Open documentation",
                "url": "https://docs.ntfy.sh/subscribe/api/",
            },
            {
                "action": "http",
                "label": "Acknowledge",
                "url": "https://example.invalid/ack",
                "method": "POST",
            },
        ],
    },
    {
        "id": "demo3-reading",
        "time": NOW - 3600,
        "event": "message",
        "topic": "lecturas",
        "title": "Reading reminder",
        "message": "This notification remains in the local archive until dismissed.",
        "priority": 3,
        "attachment": {
            "name": "example.pdf",
            "url": "https://example.org/example.pdf",
            "type": "application/pdf",
            "size": 245760,
        },
    },
]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/v1/health":
            self._send_json({"healthy": True})
            return
        if not parsed.path.endswith("/json"):
            self.send_error(404)
            return

        since = parse_qs(parsed.query).get("since", ["all"])[0]
        body = ""
        if since == "all":
            body = "\n".join(json.dumps(message) for message in MESSAGES) + "\n"
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
        self.send_header("Content-Length", str(len(body.encode())))
        self.end_headers()
        self.wfile.write(body.encode())

    def _send_json(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18098), Handler).serve_forever()
