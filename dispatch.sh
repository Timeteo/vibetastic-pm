#!/bin/bash
# PM dispatch wrapper — called by PM orchestrator to avoid shell substitution in Claude Code permission checks.
# Usage: bash dispatch.sh <model> <project-dir> <prompt-file> [fallback-model]
#
# Output capture: opencode's assistant output stays on stdout. Full opencode logs
# (--print-logs --log-level INFO) are written to a per-run logfile under logs/. On a
# non-zero exit the tail of that logfile is echoed to stderr so failures are never silent;
# on success the caller's stream stays clean. The logfile path is always printed to stderr.
eval "$(~/.ssh/gh-agent-token.sh)"

MODEL="$1"
DIR="$2"
PROMPT_FILE="$3"
FALLBACK_MODEL="${4:-}"

LOG_DIR="${OPENCODE_DISPATCH_LOG_DIR:-logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/$(basename "${PROMPT_FILE%.md}")-$(date +%Y%m%d-%H%M%S).log"

run_opencode() {
  local model="$1"
  # Assistant output -> stdout (caller). opencode logs -> logfile only (stderr appended).
  opencode run \
    --model "$model" \
    --print-logs --log-level INFO \
    --dir "$DIR" \
    --dangerously-skip-permissions \
    "$(cat "$PROMPT_FILE")" \
    2>> "$LOG_FILE"
}

run_opencode "$MODEL"
FINAL_EXIT=$?

if [ $FINAL_EXIT -ne 0 ] && [ -n "$FALLBACK_MODEL" ]; then
  echo "[dispatch] Primary model ($MODEL) failed (exit $FINAL_EXIT). Retrying with fallback: $FALLBACK_MODEL" >&2
  echo "[dispatch] --- primary attempt ($MODEL) failed at $(date) ---" >> "$LOG_FILE"
  run_opencode "$FALLBACK_MODEL"
  FINAL_EXIT=$?
fi

if [ $FINAL_EXIT -ne 0 ]; then
  echo "[dispatch] opencode failed (exit $FINAL_EXIT). Last 40 log lines:" >&2
  tail -n 40 "$LOG_FILE" >&2
fi

echo "[dispatch] full opencode log: $LOG_FILE" >&2
exit $FINAL_EXIT
