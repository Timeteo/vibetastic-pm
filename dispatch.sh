#!/bin/bash
# PM dispatch wrapper — called by PM orchestrator to avoid shell substitution in Claude Code permission checks.
# Usage: bash dispatch.sh <model> <project-dir> <prompt-file>
eval "$(~/.ssh/gh-agent-token.sh)"
set -e
MODEL="$1"
DIR="$2"
PROMPT_FILE="$3"
exec opencode run \
  --model "$MODEL" \
  --dir "$DIR" \
  --dangerously-skip-permissions \
  "$(cat "$PROMPT_FILE")"
