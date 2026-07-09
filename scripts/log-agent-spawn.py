#!/usr/bin/env python3
"""log-agent-spawn — PostToolUse hook on the Agent tool.

Subscription-side cost telemetry was previously "the orchestrator remembers to append a
cost_event" — instruction-based discipline that degrades over a long session. This hook
makes it mechanical: Claude Code invokes it after every Agent tool call, and it appends
one JSON line per spawn to logs/agent-spawns.jsonl with zero model involvement.

Wired by setup.sh into .claude/settings.json:
  "hooks": {"PostToolUse": [{"matcher": "Agent", "hooks": [{"type": "command",
    "command": "python3 \"<pm-dir>/framework/scripts/log-agent-spawn.py\""}]}]}

Input: hook JSON on stdin (tool_name, tool_input{subagent_type, model, description,
prompt}, cwd, session_id). Output: appends to $CLAUDE_PROJECT_DIR/logs/agent-spawns.jsonl
(falls back to cwd). Never fails the tool call — always exits 0.
"""
import datetime
import json
import os
import sys

try:
    data = json.load(sys.stdin)
    tool_input = data.get("tool_input") or {}
    rec = {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "role": "agent",
        "subagent_type": tool_input.get("subagent_type") or "general-purpose",
        "model": tool_input.get("model"),  # null = inherited from parent session
        "description": tool_input.get("description"),
        "session_id": data.get("session_id"),
    }
    base = os.environ.get("CLAUDE_PROJECT_DIR") or data.get("cwd") or "."
    log_dir = os.path.join(base, "logs")
    os.makedirs(log_dir, exist_ok=True)
    with open(os.path.join(log_dir, "agent-spawns.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")
except Exception:
    pass  # telemetry must never fail the tool call
sys.exit(0)
