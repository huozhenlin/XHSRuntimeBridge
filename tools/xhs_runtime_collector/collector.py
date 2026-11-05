#!/usr/bin/env python3
"""Small HTTP collector for structured runtime events.

The collector intentionally uses only the Python standard library so it can be
started easily on Windows. Incoming events are redacted before being persisted.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import threading
from collections import deque
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse


MAX_BODY_BYTES = 2 * 1024 * 1024
MAX_RECENT_EVENTS = 2_000
SENSITIVE_KEY = re.compile(
    r"(^|[-_])("
    r"authorization|cookie|set_cookie|password|passwd|secret|"
    r"access_token|refresh_token|session|session_id|sid|fid|did|device_id|"
    r"x-s|x-t|xsec_token|api_key"
    r")($|[-_])",
    re.IGNORECASE,
)


def redact(value: Any) -> Any:
    """Recursively remove credential-like values while preserving shape."""
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, child in value.items():
            text_key = str(key)
            lower_key = text_key.lower()
            describes_metadata = lower_key.endswith(
                ("_present", "-present", "_length", "-length")
            )
            if SENSITIVE_KEY.search(text_key) and not describes_metadata:
                if child in (None, "", [], {}):
                    result[text_key] = child
                else:
                    result[text_key] = "<redacted>"
                continue
            result[text_key] = redact(child)
        return result
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


class EventStore:
    def __init__(self, output_dir: Path, recent_limit: int = MAX_RECENT_EVENTS):
        self.output_dir = output_dir
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.recent: deque[dict[str, Any]] = deque(maxlen=recent_limit)
        self.lock = threading.Lock()
        self.commands: deque[dict[str, Any]] = deque(maxlen=200)

    def append(self, event: dict[str, Any], remote: str) -> dict[str, Any]:
        now = datetime.now(timezone.utc)
        normalized = {
            "received_at": now.isoformat(timespec="milliseconds"),
            "remote": remote,
            **redact(event),
        }
        line = json.dumps(
            normalized, ensure_ascii=False, separators=(",", ":")
        )
        destination = self.output_dir / f"events-{now:%Y-%m-%d}.ndjson"

        with self.lock:
            with destination.open("a", encoding="utf-8", newline="\n") as stream:
                stream.write(line)
                stream.write("\n")
            self.recent.append(normalized)
        return normalized

    def tail(self, limit: int) -> list[dict[str, Any]]:
        limit = max(1, min(limit, self.recent.maxlen or MAX_RECENT_EVENTS))
        with self.lock:
            return list(self.recent)[-limit:]

    def enqueue_command(self, command: dict[str, Any]) -> None:
        with self.lock:
            self.commands.append(command)

    def take_command(self) -> dict[str, Any] | None:
        with self.lock:
            return self.commands.popleft() if self.commands else None


class CollectorServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        store: EventStore,
        token: str,
    ):
        super().__init__(address, CollectorHandler)
        self.store = store
        self.token = token


class CollectorHandler(BaseHTTPRequestHandler):
    server: CollectorServer
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args: Any) -> None:
        print(
            f"[collector] {self.address_string()} "
            f"{datetime.now().isoformat(timespec='seconds')} {fmt % args}"
        )

    def _json_response(self, status: int, payload: Any) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _authorized(self) -> bool:
        expected = self.server.token
        if not expected:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {expected}"

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._json_response(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "service": "xhs-runtime-collector",
                    "utc": datetime.now(timezone.utc).isoformat(),
                },
            )
            return

        if parsed.path == "/commands/next":
            if not self._authorized():
                self._json_response(HTTPStatus.UNAUTHORIZED, {"ok": False})
                return
            command = self.server.store.take_command()
            self._json_response(
                HTTPStatus.OK,
                {"ok": True, "command": command},
            )
            return

        if parsed.path == "/events/recent":
            if not self._authorized():
                self._json_response(HTTPStatus.UNAUTHORIZED, {"ok": False})
                return
            raw_limit = parse_qs(parsed.query).get("limit", ["100"])[0]
            try:
                limit = int(raw_limit)
            except ValueError:
                limit = 100
            events = self.server.store.tail(limit)
            self._json_response(
                HTTPStatus.OK,
                {"ok": True, "count": len(events), "events": events},
            )
            return

        self._json_response(HTTPStatus.NOT_FOUND, {"ok": False})

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlparse(self.path).path
        if path not in ("/events", "/commands/enqueue"):
            self._json_response(HTTPStatus.NOT_FOUND, {"ok": False})
            return
        if not self._authorized():
            self._json_response(HTTPStatus.UNAUTHORIZED, {"ok": False})
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY_BYTES:
            self._json_response(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                {"ok": False, "error": "invalid body size"},
            )
            return

        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json_response(
                HTTPStatus.BAD_REQUEST,
                {"ok": False, "error": "body must be UTF-8 JSON"},
            )
            return

        if path == "/commands/enqueue":
            if not isinstance(payload, dict):
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": "command must be an object"},
                )
                return
            command = str(payload.get("command", ""))
            note_id = str(payload.get("note_id", ""))
            if command != "open_note" or not note_id:
                self._json_response(
                    HTTPStatus.BAD_REQUEST,
                    {"ok": False, "error": "expected open_note and note_id"},
                )
                return
            command_payload = {
                "command": command,
                "note_id": note_id,
                "request_id": str(
                    payload.get("request_id")
                    or f"req-{int(datetime.now().timestamp() * 1000)}"
                ),
                "queued_at": datetime.now(timezone.utc).isoformat(),
            }
            self.server.store.enqueue_command(command_payload)
            print(
                f"[command] queued {command_payload['request_id']} "
                f"note_id={note_id}"
            )
            self._json_response(
                HTTPStatus.ACCEPTED,
                {"ok": True, "request_id": command_payload["request_id"]},
            )
            return

        candidates = payload if isinstance(payload, list) else [payload]
        if not candidates or any(not isinstance(item, dict) for item in candidates):
            self._json_response(
                HTTPStatus.BAD_REQUEST,
                {"ok": False, "error": "expected an event object or event array"},
            )
            return
        if len(candidates) > 200:
            self._json_response(
                HTTPStatus.BAD_REQUEST,
                {"ok": False, "error": "batch exceeds 200 events"},
            )
            return

        remote = self.client_address[0]
        stored = [
            self.server.store.append(event, remote) for event in candidates
        ]
        for event in stored:
            event_name = event.get("event", "unknown")
            pid = event.get("pid", "")
            class_name = event.get("class", "")
            selector = event.get("selector", "")
            if event_name in ("note_detail_candidate", "note_detail_open"):
                details = " ".join(
                    f"{key}={event.get(key)}"
                    for key in (
                        "navigation",
                        "controller",
                        "model_class",
                        "note_id",
                        "user_id",
                        "source",
                        "feed_id",
                    )
                    if event.get(key) not in (None, "")
                )
                print(f"[event] {event_name} {pid} {details}".rstrip())
                continue
            details = " ".join(
                str(value)
                for value in (pid, class_name, selector)
                if value not in ("", None)
            )
            print(f"[event] {event_name} {details}".rstrip())

        self._json_response(
            HTTPStatus.ACCEPTED,
            {"ok": True, "accepted": len(stored)},
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Receive structured runtime events over HTTP."
    )
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8901)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent / "data",
    )
    parser.add_argument(
        "--token",
        default=os.environ.get("XHS_LOG_TOKEN", ""),
        help="Bearer token; defaults to XHS_LOG_TOKEN.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    store = EventStore(args.output)
    server = CollectorServer((args.host, args.port), store, args.token)
    print(f"[collector] listening on http://{args.host}:{args.port}")
    print(f"[collector] output: {args.output.resolve()}")
    print(
        "[collector] authentication: "
        + ("Bearer token required" if args.token else "DISABLED")
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[collector] stopping")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
