#!/bin/bash
# PM dispatch wrapper — called by PM orchestrator to avoid shell substitution in Claude Code permission checks.
#
# Usage:
#   bash dispatch.sh <model> <project-dir> <prompt-file> [fallback-model] [verify-cmd] [max-attempts] [tier]
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
#
# Output capture: opencode assistant output stays on stdout. Full opencode + verifier logs
# go to a per-run logfile under logs/. On any non-zero exit the log tail is echoed to stderr
# so failures are never silent. The logfile path is always printed to stderr.
eval "$(~/.ssh/gh-agent-token.sh)"

MODEL="$1"
DIR="$2"
PROMPT_FILE="$3"
FALLBACK_MODEL="${4:-}"
VERIFY_CMD="${5:-}"
MAX_ATTEMPTS="${6:-3}"
TIER="${7:-}"   # optional: task tier (fast|standard|heavy), recorded in cost telemetry only

LOG_DIR="${OPENCODE_DISPATCH_LOG_DIR:-logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/$(basename "${PROMPT_FILE%.md}")-$(date +%Y%m%d-%H%M%S).log"

# Active model — may switch to the fallback on an infra failure of the initial run.
ACTIVE_MODEL="$MODEL"

# --- Cost telemetry ---
# Append one structured record per dispatch to logs/cost.jsonl. Always-available signals
# (model, tier, attempts, verify result, exit, wall-clock) plus best-effort token counts
# grepped from the opencode log when present. framework/cost-report.sh rolls these up.
# Never fatal — telemetry must not affect the dispatch exit code.
START_EPOCH="$(date +%s)"
ATTEMPTS_USED=1

emit_cost() {
  local code="$1" end_epoch dur in_tok out_tok verify_passed
  end_epoch="$(date +%s)"
  dur=$(( end_epoch - START_EPOCH ))
  in_tok="$(grep -oiE '(input|prompt)_tokens[":= ]+[0-9]+' "$LOG_FILE" 2>/dev/null | grep -oE '[0-9]+$' | tail -1)"
  out_tok="$(grep -oiE '(output|completion)_tokens[":= ]+[0-9]+' "$LOG_FILE" 2>/dev/null | grep -oE '[0-9]+$' | tail -1)"
  [ "$code" -eq 0 ] && verify_passed=true || verify_passed=false
  printf '{"ts":"%s","role":"opencode","prompt":"%s","model":"%s","tier":"%s","attempts":%s,"verify_passed":%s,"exit":%s,"duration_s":%s,"input_tokens":%s,"output_tokens":%s,"log":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$PROMPT_FILE")" "$ACTIVE_MODEL" "$TIER" \
    "${ATTEMPTS_USED:-1}" "$verify_passed" "$code" "$dur" "${in_tok:-null}" "${out_tok:-null}" \
    "$(basename "$LOG_FILE")" >> "${LOG_DIR}/cost.jsonl" 2>/dev/null || true
}

run_opencode_fresh() {
  local model="$1"
  # Fresh session seeded with the task prompt file.
  opencode run \
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
  opencode run \
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
