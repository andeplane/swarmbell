#!/usr/bin/env python3
"""Exercise the real CLI against private synthetic caches; never collect agents."""
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="swarmbell-read-current-") as temporary:
    root = Path(temporary).resolve()
    cache = root / "cache"
    cache.mkdir(mode=0o700)
    traps = root / "bin"
    traps.mkdir(mode=0o700)
    marker = root / "provider-invoked"
    for name in ("claude", "codex"):
        script = traps / name
        script.write_text(f"#!/bin/sh\nprintf invoked > '{marker}'\nexit 99\n")
        script.chmod(0o700)
    environment = dict(os.environ, PATH=str(traps))

    def run(*arguments):
        return subprocess.run(
            [binary, *arguments], env=environment, capture_output=True, text=True, timeout=5
        )

    absent = root / "does-not-exist"
    result = run("--read-current", "--cache-directory", str(absent))
    assert result.returncode == 1 and result.stdout == "" and not absent.exists()
    history = root / "must-not-create.sqlite"
    result = run("--read-current", "--history", str(history))
    assert result.returncode == 1 and not history.exists()
    result = run("--read-current", "--install-cursor-observer")
    assert result.returncode == 1 and result.stdout == ""
    assert list(cache.iterdir()) == []

    collector = "11111111-1111-4111-8111-111111111111"
    now = dt.datetime.now(dt.timezone.utc)

    def timestamp(value):
        return value.isoformat(timespec="microseconds").replace("+00:00", "Z")

    instant = timestamp(now)
    identity = {"schemaVersion": 1, "collectorId": collector}
    snapshot = {
        "schemaVersion": 1, "generatedAt": instant,
        "counts": {"active": 1, "needsYou": 1, "working": 0, "uncertain": 1, "incomplete": True},
        "providers": [{"harness": "codex", "health": "unavailable", "message": "fixture outage",
                       "checkedAt": instant, "observesAttention": False, "scope": "fixture"}],
        "agents": [{"host": "local", "harness": "claudeCode", "sessionID": "fixture",
                    "title": "Synthetic waiting session", "state": "needsYou", "reason": "question",
                    "lastSeen": instant, "changedAt": instant, "freshness": "stale",
                    "isSubagent": False, "navigation": {"kind": "copySessionID", "arguments": [],
                    "explanation": "No action is executed"}}],
    }
    envelope = {
        "schemaVersion": 1, "collectorId": collector,
        "runId": "22222222-2222-4222-8222-222222222222", "sequence": 1,
        "observedAt": instant, "publishedAt": instant,
        "expectedRefreshIntervalSeconds": 5, "snapshot": snapshot,
    }

    def write(name, value):
        path = cache / name
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    write("identity.json", identity)
    write("current.json", envelope)
    original = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in cache.iterdir()}
    result = run("--read-current", "--cache-directory", str(cache))
    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)
    assert data["availability"] == "current"
    assert data["envelope"]["snapshot"]["counts"] == snapshot["counts"]
    assert data["envelope"]["snapshot"]["agents"][0]["freshness"] == "stale"
    assert data["envelope"]["snapshot"]["providers"][0]["health"] == "unavailable"
    assert {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in cache.iterdir()} == original

    old = timestamp(now - dt.timedelta(seconds=100))
    envelope["observedAt"] = old
    envelope["snapshot"]["generatedAt"] = old
    write("current.json", envelope)
    result = run("--cache-directory", str(cache), "--read-current")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["availability"] == "stale"

    envelope["schemaVersion"] = 2
    write("current.json", envelope)
    assert run("--read-current", "--cache-directory", str(cache)).returncode == 1
    cache.chmod(0o755)
    assert run("--read-current", "--cache-directory", str(cache)).returncode == 1
    assert cache.stat().st_mode & 0o777 == 0o755
    assert not marker.exists(), "A read-current invocation executed a provider"

print("CLI read-current: missing/invalid/stale/current cases passed; no provider or file writes")
