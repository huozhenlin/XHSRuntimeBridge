#!/usr/bin/env python3
"""Controlled note-detail open/back stability runner.

Reads only non-empty XHS note IDs from the local SQLite snapshot, queues an
``open_note`` command for each candidate, waits for a runtime route-observed
event, then queues ``go_back`` before moving to the next candidate.

This tool uses the collector's documented HTTP endpoints. It intentionally
does not access or export credentials, cookies, xsec tokens, or note content.
"""

from __future__ import annotations

import argparse
import json
import random
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_DB = Path(__file__).resolve().parents[2] / "database" / "sqlite_tables.db"
DEFAULT_COLLECTOR = "http://172.18.177.3:8901"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def request_json(
    url: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    timeout: float = 10.0,
) -> dict[str, Any]:
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = Request(url, data=body, headers=headers, method=method)
    try:
        with urlopen(request, timeout=timeout) as response:
            parsed = json.loads(response.read().decode("utf-8"))
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"{method} {url}: {exc}") from exc
    if not isinstance(parsed, dict):
        raise RuntimeError(f"{method} {url}: expected JSON object")
    return parsed


def load_note_records(
    database: Path,
    limit: int,
    keyword: str = "",
) -> list[tuple[str, str, str, str]]:
    keyword = keyword.strip()
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        rows = connection.execute(
            """
            SELECT
                note.note_id,
                LOWER(COALESCE(note.type, 'normal')),
                COALESCE(note.title, ''),
                COALESCE(note.source_keyword, '')
            FROM xhs_note AS note
            INNER JOIN (
                SELECT note_id, MAX(id) AS latest_id
                FROM xhs_note
                WHERE note_id IS NOT NULL
                  AND TRIM(note_id) <> ''
                  AND (
                      ? = ''
                      OR INSTR(COALESCE(source_keyword, ''), ?) > 0
                  )
                GROUP BY note_id
            ) AS latest
                ON latest.latest_id = note.id
            ORDER BY note.id DESC
            LIMIT ?
            """,
            (keyword, keyword, limit),
        ).fetchall()
    finally:
        connection.close()
    return [
        (
            str(note_id).strip(),
            note_type if note_type in ("normal", "video") else "normal",
            str(title or "").strip(),
            str(source_keyword or "").strip(),
        )
        for note_id, note_type, title, source_keyword in rows
        if str(note_id).strip()
    ]


def append_record(destination: Path, record: dict[str, Any]) -> None:
    with destination.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
        stream.write("\n")


def detail_opened(
    collector: str,
    note_id: str,
    *,
    after_ms: int,
    limit: int = 200,
) -> bool:
    response = request_json(f"{collector}/events/recent?limit={limit}")
    events = response.get("events", [])
    if not isinstance(events, list):
        return False
    for event in reversed(events):
        if not isinstance(event, dict):
            continue
        if event.get("event") not in ("note_detail_open", "note_route_observed"):
            continue
        if str(event.get("note_id", "")) != note_id:
            continue
        try:
            event_time = int(event.get("event_time_ms", 0))
        except (TypeError, ValueError):
            event_time = 0
        if event_time >= after_ms:
            return True
    return False


def enqueue(collector: str, command: dict[str, Any]) -> str:
    response = request_json(
        f"{collector}/commands/enqueue",
        method="POST",
        payload=command,
    )
    if response.get("ok") is not True:
        raise RuntimeError(f"collector rejected command: {response}")
    return str(response.get("request_id", ""))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Open XHS note details and return, recording stability results."
    )
    parser.add_argument("--database", type=Path, default=DEFAULT_DB)
    parser.add_argument("--collector", default=DEFAULT_COLLECTOR)
    parser.add_argument("--count", type=int, default=1000)
    parser.add_argument(
        "--keyword",
        default="",
        help="Literal substring matched against xhs_note.source_keyword only.",
    )
    parser.add_argument(
        "--minimum-detail-dwell",
        type=float,
        default=5.0,
        help="Seconds to keep a confirmed detail route open before go_back.",
    )
    parser.add_argument(
        "--maximum-detail-dwell",
        type=float,
        default=10.0,
        help="Maximum seconds to keep a confirmed detail route open.",
    )
    parser.add_argument(
        "--between-cases-delay",
        type=float,
        default=1.0,
        help="Fixed pause after go_back before opening the next test case.",
    )
    parser.add_argument("--open-timeout", type=float, default=12.0)
    parser.add_argument("--poll-interval", type=float, default=0.5)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent
        / "data"
        / f"note-detail-stability-{datetime.now():%Y%m%d-%H%M%S}.ndjson",
    )
    parser.add_argument(
        "--strategy",
        default="url_scheme",
        choices=("tracker", "auto", "xy_note_api", "url_scheme"),
        help="Uses direct URL Scheme by default.",
    )
    return parser.parse_args()


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="backslashreplace")
    args = parse_args()
    if args.count <= 0:
        raise SystemExit("--count must be positive")
    if (
        args.minimum_detail_dwell <= 0
        or args.maximum_detail_dwell < args.minimum_detail_dwell
        or args.between_cases_delay < 0
    ):
        raise SystemExit("invalid dwell or between-case delay")
    if not args.database.is_file():
        raise SystemExit(f"database not found: {args.database}")

    collector = args.collector.rstrip("/")
    note_records = load_note_records(args.database, args.count, args.keyword)
    if not note_records:
        raise SystemExit("no usable note_id rows in xhs_note")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    print(
        f"Starting controlled stability run: {len(note_records)} note IDs; "
        f"collector={collector}; keyword={args.keyword!r}; output={args.output}",
        flush=True,
    )

    for sequence, (note_id, note_type, title, source_keyword) in enumerate(
        note_records,
        start=1,
    ):
        open_sent_ms = int(time.time() * 1000)
        record: dict[str, Any] = {
            "sequence": sequence,
            "note_id": note_id,
            "note_type": note_type,
            "title": title,
            "source_keyword": source_keyword,
            "started_at": utc_now(),
            "open_status": "not_sent",
            "back_status": "not_sent",
        }
        try:
            record["open_request_id"] = enqueue(
                collector,
                {
                    "command": "open_note",
                    "note_id": note_id,
                    "note_type": note_type,
                    "strategy": args.strategy,
                },
            )
            record["open_status"] = "queued"

            deadline = time.monotonic() + args.open_timeout
            while time.monotonic() < deadline:
                if detail_opened(collector, note_id, after_ms=open_sent_ms):
                    record["open_status"] = "detail_opened"
                    break
                time.sleep(args.poll_interval)
            else:
                record["open_status"] = "timed_out"

            if record["open_status"] == "route_observed":
                dwell = random.uniform(
                    args.minimum_detail_dwell,
                    args.maximum_detail_dwell,
                )
                record["detail_dwell_seconds"] = round(dwell, 3)
                time.sleep(dwell)

            # Return after either a confirmed dwell or a timeout, so a
            # delayed navigation cannot leave the device on an unexpected page.
            record["back_request_id"] = enqueue(collector, {"command": "go_back"})
            record["back_status"] = "queued"
        except Exception as exc:  # Record and continue with the next test case.
            record["error"] = str(exc)
            if record["open_status"] == "not_sent":
                record["open_status"] = "error"
            if record["back_status"] == "not_sent":
                record["back_status"] = "skipped"
        finally:
            record["finished_at"] = utc_now()
            append_record(args.output, record)
            print(
                f"[{sequence}/{len(note_records)}] {note_id} ({note_type}) "
                f"source_keyword={source_keyword[:100]!r} "
                f"title={title.replace(chr(10), ' ').replace(chr(13), ' ')[:160]!r} "
                f"open={record['open_status']} back={record['back_status']}",
                flush=True,
            )

            if args.between_cases_delay > 0 and sequence < len(note_records):
                time.sleep(args.between_cases_delay)

    print(f"Completed: {args.output}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
