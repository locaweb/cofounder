#!/usr/bin/env python3
#
# Build a stream-json-shaped transcript for an agy (Antigravity) run, so the
# Claude-shaped deterministic asserts in test-agent.sh and the distiller in
# judge.sh work UNCHANGED across harnesses.
#
# Why this exists: agy has no JSON/stream output — `agy -p` prints only the
# final assistant prose. Its real tool trace (skill loads, shell commands)
# lives in a per-conversation SQLite "trajectory store" as protobuf blobs.
# We reconstruct a transcript by emitting the same keys the other harnesses do:
#   {"text": "<assistant prose>"}                       -> narration
#   {"name": "<tool>", "command": "<cmdline|skillpath>"} -> each tool/command
#
# Usage: agy-transcript.py <conversation.db> <prose-file>   (prints JSONL)
import json
import re
import sqlite3
import sys

db, prose_file = sys.argv[1], sys.argv[2]


def readable(b):
    """Latin1-ish view of a proto blob: keep printable bytes, blank the rest.
    Proto preserves UTF-8/ASCII string fields inline, so embedded JSON
    fragments ("CommandLine":..., SKILL.md paths) survive this."""
    return "".join(chr(c) if 32 <= c < 127 else " " for c in b)


# 1) Tool trace from the trajectory DB, in step order (preflight before reply).
try:
    con = sqlite3.connect(db)
    blobs = [r[0] for r in con.execute("select step_payload from steps order by idx") if r[0]]
    con.close()
except Exception:
    blobs = []

text = " ".join(readable(b) for b in blobs)

for m in re.finditer(r'"CommandLine":"((?:[^"\\]|\\.)*)"', text):
    print(json.dumps({"name": "run_command", "command": m.group(1)[:300]}, separators=(",", ":")))

# Skill files the agent opened (cofounder-playbook, -pre-flight-check, ...).
# Anchor at .agents/skills/ so a stray proto length-prefix byte doesn't ride
# along; the path carries the skill name, which is what the asserts/judge key on.
for path in sorted(set(re.findall(r'\.agents/skills/[^\s"]*SKILL\.md', text))):
    print(json.dumps({"name": "view_skill", "command": path}, separators=(",", ":")))

# 2) Assistant narration: the printed prose (also carries the [Cofounder] tag).
# Emit ONE text event per non-blank line, not one giant block: judge.sh's
# distill() does `cut -c1-500` per text event (fine for the many small events
# the JSON harnesses produce), so a single long block would be truncated and
# lose later content (e.g. the "what do you want to build?" question).
try:
    with open(prose_file, encoding="utf-8", errors="replace") as f:
        prose = f.read()
except OSError:
    prose = ""
for line in prose.splitlines():
    line = line.strip()
    if line:
        print(json.dumps({"text": line}, separators=(",", ":")))
