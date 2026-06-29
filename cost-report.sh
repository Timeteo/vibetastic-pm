#!/bin/bash
# Cost rollup for the PM framework. Reads:
#   - logs/cost.jsonl   (one record per OpenCode dispatch, written by dispatch.sh)
#   - TASK_LOG.md        (cost_event entries the PM logs per planning-agent spawn)
#   - MODELS.md          (the Pricing table → $/Mtok, source of truth)
# and prints per-model rollups: runs, attempts, wall-clock, tokens, and $ estimate
# (only where tokens and a price are both known).
#
# Usage: bash framework/cost-report.sh [logs-dir] [models-file] [task-log]
# Defaults: logs/  MODELS.md  TASK_LOG.md  (relative to the PM project dir)
set -euo pipefail

LOG_DIR="${1:-logs}"
MODELS_FILE="${2:-MODELS.md}"
TASK_LOG="${3:-TASK_LOG.md}"

python3 - "$LOG_DIR/cost.jsonl" "$MODELS_FILE" "$TASK_LOG" <<'PY'
import json, re, sys, os
from collections import defaultdict

cost_jsonl, models_file, task_log = sys.argv[1:4]

# --- Parse the Pricing table from MODELS.md: slug -> (in_per_mtok, out_per_mtok) ---
prices = {}
if os.path.exists(models_file):
    in_pricing = False
    for line in open(models_file):
        if line.strip().startswith("## Pricing"):
            in_pricing = True; continue
        if in_pricing and line.startswith("## "):
            break
        if in_pricing and line.lstrip().startswith("|"):
            cells = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cells) < 3 or cells[0] in ("Model slug", "") or set(cells[0]) <= set("-"):
                continue
            slugs = [s.strip().strip("`") for s in cells[0].split("/")]
            try:
                pin, pout = float(cells[1]), float(cells[2])
            except ValueError:
                continue  # "?" or non-numeric
            for s in slugs:
                prices[s] = (pin, pout)

def price_for(model):
    if model in prices:
        return prices[model]
    # last path segment (e.g. openrouter/anthropic/claude-opus-4.8 -> claude-opus-4.8)
    return prices.get(model.rsplit("/", 1)[-1])

# --- Aggregate OpenCode dispatch records ---
agg = defaultdict(lambda: {"runs":0,"attempts":0,"dur":0,"in":0,"out":0,"fails":0,"role":"opencode"})
if os.path.exists(cost_jsonl):
    for line in open(cost_jsonl):
        line = line.strip()
        if not line: continue
        try: r = json.loads(line)
        except json.JSONDecodeError: continue
        a = agg[r.get("model","?")]
        a["role"] = r.get("role","opencode")
        a["runs"] += 1
        a["attempts"] += r.get("attempts",1) or 1
        a["dur"] += r.get("duration_s",0) or 0
        if isinstance(r.get("input_tokens"), int):  a["in"]  += r["input_tokens"]
        if isinstance(r.get("output_tokens"), int): a["out"] += r["output_tokens"]
        if not r.get("verify_passed", True): a["fails"] += 1

# --- Count planning cost_events from TASK_LOG (frequency only; tokens rarely known) ---
plan = defaultdict(int)
if os.path.exists(task_log):
    txt = open(task_log).read()
    # cost_event blocks: look for `role:` + `model:` near a cost_event header
    for m in re.finditer(r"cost_event.*?role:\s*(\S+).*?model:\s*(\S+)", txt, re.S):
        plan[(m.group(1).strip(), m.group(2).strip().strip('"`'))] += 1

def est(model, tin, tout):
    p = price_for(model)
    if not p or (tin == 0 and tout == 0): return None
    return tin/1e6*p[0] + tout/1e6*p[1]

print("=== OpenCode dispatches (from logs/cost.jsonl) ===")
if not agg:
    print("  (no records yet)")
total = 0.0
for model, a in sorted(agg.items()):
    d = est(model, a["in"], a["out"])
    dollar = f"${d:,.2f}" if d is not None else "  (tokens/price n/a)"
    if d: total += d
    print(f"  {model}")
    print(f"     runs={a['runs']}  verify-fails={a['fails']}  attempts={a['attempts']}  "
          f"wall={a['dur']}s  in={a['in']:,}  out={a['out']:,}  est={dollar}")
if total:
    print(f"  ── OpenCode estimated total: ${total:,.2f} (only models with tokens+price)")

print("\n=== Planning / PM agent spawns (from TASK_LOG cost_event) ===")
if not plan:
    print("  (no cost_event entries — see state.md to enable PM-side logging)")
for (role, model), n in sorted(plan.items()):
    print(f"  {role:10s} {model:14s} ×{n}")
PY
