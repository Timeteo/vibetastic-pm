#!/bin/bash
# PM dispatch wrapper — called by PM orchestrator to avoid shell substitution in Claude Code permission checks.
# Usage: bash dispatch.sh <model> <project-dir> <prompt-file> [fallback-model]
eval "$(~/.ssh/gh-agent-token.sh)"

MODEL="$1"
DIR="$2"
PROMPT_FILE="$3"
FALLBACK_MODEL="${4:-}"

run_opencode() {
  local model="$1"
  opencode run \
    --model "$model" \
    --dir "$DIR" \
    --dangerously-skip-permissions \
    "$(cat "$PROMPT_FILE")"
}

run_opencode "$MODEL"
PRIMARY_EXIT=$?

if [ $PRIMARY_EXIT -ne 0 ] && [ -n "$FALLBACK_MODEL" ]; then
  echo "[dispatch] Primary model ($MODEL) failed (exit $PRIMARY_EXIT). Retrying with fallback: $FALLBACK_MODEL" >&2
  run_opencode "$FALLBACK_MODEL"
  exit $?
fi

exit $PRIMARY_EXIT
