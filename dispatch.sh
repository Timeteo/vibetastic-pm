#!/bin/bash
# PM dispatch wrapper — called by PM orchestrator to avoid shell substitution in Claude Code permission checks.
#
# Usage:
#   bash dispatch.sh [--read-only] [--worktree <branch>] <model> <project-dir> <prompt-file> [fallback-model] [verify-cmd] [max-attempts] [tier]
#
# --read-only: for diagnosis/review dispatches (RULES.md lesson 2, VERIFY.md diff review).
#   The model is expected to investigate and report, changing nothing. Enforced structurally:
#   if the target git tree differs after the run (status, or content of tracked files —
#   including files that were already dirty), dispatch exits 21 (changes left in place
#   for inspection — never auto-reverted). The verify loop is skipped in this mode.
#
# --worktree <branch>: run the builder in an isolated git worktree instead of the live
#   checkout. The worktree is created at <project-dir>/../<project>-worktrees/<prompt-basename>
#   on <branch> (created from the current HEAD if it doesn't exist; reused if the path
#   already exists from a prior dispatch of the same task, e.g. a tier-escalation re-run).
#   opencode and the verifier both run inside the worktree, so the human's working tree and
#   any uncommitted work are untouchable, parallel dispatches can't collide, and opencode's
#   per-directory session store makes --continue unambiguous per task. The worktree is left
#   in place — the PM inspects it, opens the PR from its branch, then removes it with
#   `git worktree remove <path>`. The worktree path is printed to stderr as
#   "[dispatch] worktree: <path>".
#
# Runs opencode on the task. If <verify-cmd> is given, it then verifies the working tree
# and self-corrects: on a failed verify it continues the SAME opencode session with the
# verifier output appended and re-verifies, up to <max-attempts> verify checks (default 3).
# This inner correction loop runs entirely in bash — no PM tokens are spent per iteration.
#
# Exit codes (the PM branches on these):
#   0   success — opencode ran and, if a verifier was given, it passed
#   1   opencode infra/model failure — could not produce a run even via the fallback model
#   20  verify never passed within max-attempts — code runs but is wrong -> PM escalates tier
#   21  --read-only violated — the run modified the target tree (changes left for inspection)
#
# Output capture: opencode assistant output stays on stdout. Full opencode + verifier logs
# go to a per-run logfile under logs/. On any non-zero exit the log tail is echoed to stderr
# so failures are never silent. The logfile path is always printed to stderr.
eval "$(~/.ssh/gh-agent-token.sh)"

READ_ONLY=false
WORKTREE_BRANCH=""
while true; do
  case "$1" in
    --read-only) READ_ONLY=true; shift ;;
    --worktree)  WORKTREE_BRANCH="$2"; shift 2 ;;
    *) break ;;
  esac
done

MODEL="$1"
DIR="$2"
PROMPT_FILE="$3"
FALLBACK_MODEL="${4:-}"
VERIFY_CMD="${5:-}"
MAX_ATTEMPTS="${6:-3}"
TIER="${7:-}"   # optional: task tier (fast|standard|heavy), recorded in cost telemetry only

# Logs anchor to the PM directory, not the caller's cwd: the task prompt always lives in
# <pm-dir>/prompts/, so default LOG_DIR to the prompts dir's sibling logs/. This keeps
# cost.jsonl and run logs in one place no matter where the orchestrator invokes dispatch
# from (e.g. the <project>-run partner workspace). OPENCODE_DISPATCH_LOG_DIR overrides.
if [ -n "${OPENCODE_DISPATCH_LOG_DIR:-}" ]; then
  LOG_DIR="$OPENCODE_DISPATCH_LOG_DIR"
else
  PROMPT_DIR="$(cd "$(dirname "$PROMPT_FILE")" 2>/dev/null && pwd)"
  LOG_DIR="${PROMPT_DIR:+$(dirname "$PROMPT_DIR")/logs}"
  LOG_DIR="${LOG_DIR:-logs}"
fi
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/$(basename "${PROMPT_FILE%.md}")-$(date +%Y%m%d-%H%M%S).log"

# Active model — may switch to the fallback on an infra failure of the initial run.
ACTIVE_MODEL="$MODEL"

# Per-opencode-call wall-clock cap. A stalled model (e.g. a reasoning model burning its whole
# token budget on `reasoning` with no content/tool-call) otherwise hangs this call indefinitely
# — observed as a multi-hour no-op in logs/. On timeout, `timeout` exits 124, which flows through
# the same path as any non-zero opencode exit (fallback once, then a non-zero return to the PM),
# so a hang fails fast and cheap instead of stalling then needlessly escalating tiers. Override
# with OPENCODE_DISPATCH_TIMEOUT (seconds); 0 disables. No-op if `timeout` isn't on PATH.
DISPATCH_TIMEOUT="${OPENCODE_DISPATCH_TIMEOUT:-900}"
if [ "$DISPATCH_TIMEOUT" != "0" ] && command -v timeout >/dev/null 2>&1; then
  TIMEOUT_PREFIX=(timeout "$DISPATCH_TIMEOUT")
else
  TIMEOUT_PREFIX=()
fi

# --- Cost telemetry ---
# Append one structured record per dispatch to logs/cost.jsonl. Always-available signals
# (model, tier, attempts, verify result, exit, wall-clock) plus authoritative cost/token
# figures from opencode's local session store (~/.local/share/opencode/opencode.db): the
# `session` table records per-session cost (USD, as billed by OpenRouter) and token counts.
# We sum every session created in the target dir during this dispatch — that covers the
# primary run, --continue turns (same session), and a fallback-model rerun (second session).
# opencode's INFO logs do NOT carry usage, so the DB is the only reliable source.
# Never fatal — telemetry must not affect the dispatch exit code.
START_EPOCH="$(date +%s)"
ATTEMPTS_USED=1
OPENCODE_DB="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
DIR_ABS="$(cd "$DIR" 2>/dev/null && pwd || echo "$DIR")"

# --- Worktree isolation: builders never touch the live checkout ---
if [ -n "$WORKTREE_BRANCH" ]; then
  WT_ROOT="$(dirname "$DIR_ABS")/$(basename "$DIR_ABS")-worktrees"
  WT_PATH="${WT_ROOT}/$(basename "${PROMPT_FILE%.md}")"
  mkdir -p "$WT_ROOT"
  if [ ! -d "$WT_PATH" ]; then
    if git -C "$DIR_ABS" show-ref --verify --quiet "refs/heads/${WORKTREE_BRANCH}"; then
      git -C "$DIR_ABS" worktree add "$WT_PATH" "$WORKTREE_BRANCH" >&2 \
        || { echo "[dispatch] worktree add failed (branch ${WORKTREE_BRANCH})" >&2; exit 1; }
    else
      git -C "$DIR_ABS" worktree add -b "$WORKTREE_BRANCH" "$WT_PATH" >&2 \
        || { echo "[dispatch] worktree add -b failed (branch ${WORKTREE_BRANCH})" >&2; exit 1; }
    fi
  fi
  DIR="$WT_PATH"
  DIR_ABS="$WT_PATH"
  echo "[dispatch] worktree: $WT_PATH (branch ${WORKTREE_BRANCH})" >&2
fi

emit_cost() {
  local code="$1" end_epoch dur verify_passed row cost_usd in_tok out_tok cache_tok
  end_epoch="$(date +%s)"
  dur=$(( end_epoch - START_EPOCH ))
  if [ -z "$VERIFY_CMD" ]; then
    verify_passed=null   # no verifier configured — exit 0 means "opencode ran", not "verified"
  elif [ "$code" -eq 0 ]; then
    verify_passed=true
  else
    verify_passed=false
  fi
  cost_usd=null; in_tok=null; out_tok=null; cache_tok=null
  if command -v sqlite3 >/dev/null 2>&1 && [ -r "$OPENCODE_DB" ]; then
    row="$(sqlite3 -separator '|' "$OPENCODE_DB" \
      "select round(coalesce(sum(cost),0),6), coalesce(sum(tokens_input),0), coalesce(sum(tokens_output+tokens_reasoning),0), coalesce(sum(tokens_cache_read),0) \
       from session where directory='${DIR_ABS//\'/\'\'}' and time_created >= ${START_EPOCH}000;" 2>/dev/null)"
    if [ -n "$row" ]; then
      IFS='|' read -r cost_usd in_tok out_tok cache_tok <<< "$row"
    fi
  fi
  printf '{"ts":"%s","role":"opencode","prompt":"%s","model":"%s","tier":%s,"attempts":%s,"verify_passed":%s,"exit":%s,"duration_s":%s,"cost_usd":%s,"input_tokens":%s,"output_tokens":%s,"cache_read_tokens":%s,"log":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$PROMPT_FILE")" "$ACTIVE_MODEL" \
    "$([ -n "$TIER" ] && printf '"%s"' "$TIER" || echo null)" \
    "${ATTEMPTS_USED:-1}" "$verify_passed" "$code" "$dur" \
    "${cost_usd:-null}" "${in_tok:-null}" "${out_tok:-null}" "${cache_tok:-null}" \
    "$(basename "$LOG_FILE")" >> "${LOG_DIR}/cost.jsonl" 2>/dev/null || true
}

run_opencode_fresh() {
  local model="$1"
  # Fresh session seeded with the task prompt file.
  "${TIMEOUT_PREFIX[@]}" opencode run \
    --model "$model" \
    --print-logs --log-level INFO \
    --dir "$DIR" \
    --dangerously-skip-permissions \
    "$(cat "$PROMPT_FILE")" \
    2>> "$LOG_FILE"
}

run_opencode_continue() {
  local model="$1" message="$2"
  # Continue the most recent session in DIR (dispatches run one at a time) with a new message.
  "${TIMEOUT_PREFIX[@]}" opencode run \
    --continue \
    --model "$model" \
    --print-logs --log-level INFO \
    --dir "$DIR" \
    --dangerously-skip-permissions \
    "$message" \
    2>> "$LOG_FILE"
}

run_verify() {
  # Run the verifier in the target dir; tee combined output to the logfile. Returns its exit.
  echo "[dispatch] --- verify: $VERIFY_CMD ($(date)) ---" >> "$LOG_FILE"
  ( cd "$DIR" && bash -c "$VERIFY_CMD" ) > "$LOG_DIR/.verify.out" 2>&1
  local vec=$?
  cat "$LOG_DIR/.verify.out" >> "$LOG_FILE"
  return $vec
}

finish() {
  local code="$1"
  emit_cost "$code"
  if [ "$code" -ne 0 ]; then
    echo "[dispatch] failed (exit $code). Last 40 log lines:" >&2
    tail -n 40 "$LOG_FILE" >&2
  fi
  echo "[dispatch] full log: $LOG_FILE" >&2
  exit "$code"
}

# --- Read-only mode: snapshot the tree state so violations are detectable ---
# Snapshot = porcelain status (catches new/deleted/newly-modified files) + a hash of the
# full diff against HEAD (catches further edits to files that were ALREADY dirty, which
# leave the status line unchanged).
tree_state() {
  {
    git -C "$DIR_ABS" status --porcelain | sort
    git -C "$DIR_ABS" diff HEAD | shasum
  } 2>/dev/null
}
if $READ_ONLY; then
  TREE_BEFORE="$(tree_state)"
fi

# --- Initial run (with fallback on infra failure) ---
run_opencode_fresh "$ACTIVE_MODEL"
if [ $? -ne 0 ]; then
  if [ -n "$FALLBACK_MODEL" ]; then
    echo "[dispatch] Primary model ($ACTIVE_MODEL) failed. Retrying with fallback: $FALLBACK_MODEL" >&2
    echo "[dispatch] --- primary ($ACTIVE_MODEL) infra failure at $(date) ---" >> "$LOG_FILE"
    ACTIVE_MODEL="$FALLBACK_MODEL"
    run_opencode_fresh "$ACTIVE_MODEL" || finish 1
  else
    finish 1
  fi
fi

# --- Read-only mode: enforce that nothing changed; no verify loop ---
if $READ_ONLY; then
  TREE_AFTER="$(tree_state)"
  if [ "$TREE_BEFORE" != "$TREE_AFTER" ]; then
    echo "[dispatch] read-only violation — the run modified the target tree:" >&2
    diff <(echo "$TREE_BEFORE") <(echo "$TREE_AFTER") >&2 || true
    echo "[dispatch] changes left in place for inspection (not reverted)." >&2
    finish 21
  fi
  finish 0
fi

# --- No verifier configured: preserve legacy behavior (build/no-op check is the PM's job) ---
[ -z "$VERIFY_CMD" ] && finish 0

# --- Verify + self-correct loop ---
attempt=1
while true; do
  ATTEMPTS_USED="$attempt"
  if run_verify; then
    echo "[dispatch] verify passed on attempt $attempt/$MAX_ATTEMPTS." >&2
    finish 0
  fi

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "[dispatch] verify still failing after $MAX_ATTEMPTS attempts — escalation needed." >&2
    finish 20
  fi

  echo "[dispatch] verify failed (attempt $attempt/$MAX_ATTEMPTS). Feeding error back to $ACTIVE_MODEL." >&2
  FEEDBACK="$(printf 'The verification command failed. Fix the code so it passes, then stop.\n\nCommand:\n%s\n\nOutput (tail):\n%s\n' \
    "$VERIFY_CMD" "$(tail -c 8000 "$LOG_DIR/.verify.out")")"

  run_opencode_continue "$ACTIVE_MODEL" "$FEEDBACK" || finish 1
  attempt=$((attempt + 1))
done
