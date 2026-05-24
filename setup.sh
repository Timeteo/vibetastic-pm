#!/bin/bash
# vibetastic-pm project setup — run once before the first PM session.
# Usage: bash framework/setup.sh <project-name> <absolute-path-to-code-dir>
#
# Writes:
#   .claude/settings.json   — allowlist for cross-directory operations
#   PROJECT.md              — project paths for PM sessions

set -e

if [ $# -ne 2 ]; then
  echo "Usage: bash framework/setup.sh <project-name> <absolute-path-to-code-dir>"
  echo "Example: bash framework/setup.sh hometastic /Users/tim/Developer/hometastic-code"
  exit 1
fi

PROJECT_NAME="$1"
CODE_DIR="$2"
PM_DIR="$(pwd)"

if [ ! -d "$CODE_DIR" ]; then
  echo "Error: code directory does not exist: $CODE_DIR"
  exit 1
fi

# Write .claude/settings.json
mkdir -p .claude
cat > .claude/settings.json <<EOF
{
  "permissions": {
    "allow": [
      "Bash(bash framework/dispatch.sh *)",
      "Bash(opencode *)",
      "Bash(eval \"\$(~/.ssh/gh-agent-token.sh)\"*)",
      "Bash(git *)",
      "Bash(gh *)",
      "Bash(bash *)",
      "Read(${CODE_DIR}/**)",
      "Edit(${CODE_DIR}/**)",
      "Write(${CODE_DIR}/**)",
      "Read(${PM_DIR}/**)",
      "Edit(${PM_DIR}/**)",
      "Write(${PM_DIR}/**)"
    ]
  }
}
EOF

echo "✓ Wrote .claude/settings.json"

# Write PROJECT.md
cat > PROJECT.md <<EOF
---
project: ${PROJECT_NAME}
setup_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

## Project Paths

| Key | Path |
|-----|------|
| PM directory | \`${PM_DIR}\` |
| Code directory | \`${CODE_DIR}\` |

## Notes

<!-- Add any project-specific notes here for future PM sessions. -->
EOF

echo "✓ Wrote PROJECT.md"
echo ""
echo "Setup complete. Start the PM with: claude"
