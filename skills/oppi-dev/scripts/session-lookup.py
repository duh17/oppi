#!/usr/bin/env python3
"""Look up pi-remote sessions from filesystem or REST API.

Usage:
    session-lookup.py list [--limit N]       List recent sessions
    session-lookup.py get <session-id>       Show session detail
    session-lookup.py trace <session-id>     Print JSONL trace path
    session-lookup.py latest                 Show most recent session
    session-lookup.py latest --trace         Print latest JSONL trace path
    session-lookup.py latest --jsonl         Cat the latest JSONL file
"""

import json
import sys
import os
import glob
import datetime
from pathlib import Path

CONFIG_DIR = Path.home() / ".config" / "pi-remote"
SESSIONS_DIR = CONFIG_DIR / "sessions"
USERS_FILE = CONFIG_DIR / "users.json"


def load_all_sessions():
    """Load all session JSON files, sorted by lastActivity desc."""
    sessions = []
    for path in SESSIONS_DIR.rglob("*.json"):
        try:
            data = json.loads(path.read_text())
            s = data["session"]
            s["_path"] = str(path)
            s["_messages"] = data.get("messages", [])
            sessions.append(s)
        except (json.JSONDecodeError, KeyError):
            continue
    sessions.sort(key=lambda x: x.get("lastActivity", 0), reverse=True)
    return sessions


def format_session_line(s):
    """One-line summary of a session."""
    ts = s.get("lastActivity", 0)
    dt = datetime.datetime.fromtimestamp(ts / 1000).strftime("%Y-%m-%d %H:%M") if ts else "?"
    msg = (s.get("lastMessage") or "")[:60]
    return (
        f'{s["id"]:12} {s.get("status", "?"):8} '
        f'{s.get("workspaceName", "?"):12} {s.get("runtime", "?"):9} '
        f'{dt}  msgs={s.get("messageCount", 0):3}  '
        f'${s.get("cost", 0):.4f}  {msg}'
    )


def format_session_detail(s):
    """Multi-line detail of a session."""
    ts = s.get("lastActivity", 0)
    dt = datetime.datetime.fromtimestamp(ts / 1000).strftime("%Y-%m-%d %H:%M:%S") if ts else "?"
    created = s.get("createdAt", 0)
    created_dt = datetime.datetime.fromtimestamp(created / 1000).strftime("%Y-%m-%d %H:%M:%S") if created else "?"
    lines = [
        f'Session:    {s["id"]}',
        f'User:       {s.get("userId", "?")}',
        f'Status:     {s.get("status", "?")}',
        f'Model:      {s.get("model", "?")}',
        f'Workspace:  {s.get("workspaceName", "?")}',
        f'Runtime:    {s.get("runtime", "?")}',
        f'Created:    {created_dt}',
        f'Last:       {dt}',
        f'Messages:   {s.get("messageCount", 0)}',
        f'Cost:       ${s.get("cost", 0):.4f}',
        f'Context:    {s.get("contextTokens", "?")}/{s.get("contextWindow", "?")}',
        f'JSONL:      {s.get("piSessionFile", "none")}',
    ]
    warnings = s.get("warnings", [])
    if warnings:
        lines.append(f'Warnings:   {"; ".join(warnings)}')
    last_msg = s.get("lastMessage", "")
    if last_msg:
        lines.append(f'Last msg:   {last_msg[:120]}')
    return "\n".join(lines)


def find_session(session_id, sessions=None):
    """Find a session by ID."""
    if sessions is None:
        sessions = load_all_sessions()
    for s in sessions:
        if s["id"] == session_id:
            return s
    return None


def cmd_list(limit=10):
    sessions = load_all_sessions()
    for s in sessions[:limit]:
        print(format_session_line(s))


def cmd_get(session_id):
    s = find_session(session_id)
    if not s:
        print(f"Session {session_id} not found", file=sys.stderr)
        sys.exit(1)
    print(format_session_detail(s))


def cmd_trace(session_id):
    s = find_session(session_id)
    if not s:
        print(f"Session {session_id} not found", file=sys.stderr)
        sys.exit(1)
    jsonl = s.get("piSessionFile", "")
    if not jsonl:
        print("No JSONL trace file", file=sys.stderr)
        sys.exit(1)
    print(jsonl)


def cmd_latest(show_trace=False, cat_jsonl=False):
    sessions = load_all_sessions()
    if not sessions:
        print("No sessions found", file=sys.stderr)
        sys.exit(1)
    s = sessions[0]
    if show_trace or cat_jsonl:
        jsonl = s.get("piSessionFile", "")
        if not jsonl:
            print("No JSONL trace file", file=sys.stderr)
            sys.exit(1)
        if cat_jsonl:
            try:
                print(Path(jsonl).read_text(), end="")
            except FileNotFoundError:
                print(f"JSONL file not found: {jsonl}", file=sys.stderr)
                sys.exit(1)
        else:
            print(jsonl)
    else:
        print(format_session_detail(s))


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__.strip())
        sys.exit(0)

    cmd = args[0]

    if cmd == "list":
        limit = 10
        if "--limit" in args:
            idx = args.index("--limit")
            limit = int(args[idx + 1])
        cmd_list(limit)

    elif cmd == "get":
        if len(args) < 2:
            print("Usage: session-lookup.py get <session-id>", file=sys.stderr)
            sys.exit(1)
        cmd_get(args[1])

    elif cmd == "trace":
        if len(args) < 2:
            print("Usage: session-lookup.py trace <session-id>", file=sys.stderr)
            sys.exit(1)
        cmd_trace(args[1])

    elif cmd == "latest":
        cmd_latest(
            show_trace="--trace" in args,
            cat_jsonl="--jsonl" in args,
        )

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
