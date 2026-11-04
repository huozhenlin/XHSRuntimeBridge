from pathlib import Path

from tools.xhs_runtime_collector.collector import EventStore, redact


def test_redact_recursively_masks_credentials():
    source = {
        "event": "request",
        "authorization": "Bearer secret",
        "headers": {
            "Cookie": "sid=secret",
            "content-type": "application/json",
        },
        "items": [
            {"xsec_token": "secret", "xsec_token_present": True},
            {"value": 1},
        ],
    }

    result = redact(source)

    assert result["authorization"] == "<redacted>"
    assert result["headers"]["Cookie"] == "<redacted>"
    assert result["headers"]["content-type"] == "application/json"
    assert result["items"][0]["xsec_token"] == "<redacted>"
    assert result["items"][0]["xsec_token_present"] is True
    assert result["items"][1]["value"] == 1


def test_event_store_appends_ndjson(tmp_path: Path):
    store = EventStore(tmp_path)

    stored = store.append(
        {"event": "dylib_loaded", "sid": "secret"},
        "192.0.2.1",
    )

    assert stored["event"] == "dylib_loaded"
    assert stored["sid"] == "<redacted>"
    assert store.tail(1)[0]["remote"] == "192.0.2.1"

    files = list(tmp_path.glob("events-*.ndjson"))
    assert len(files) == 1
    text = files[0].read_text(encoding="utf-8")
    assert '"event":"dylib_loaded"' in text
    assert "secret" not in text
