#!/bin/bash
# vibetastic-pm project setup — run once before the first PM session.
# Usage: bash framework/setup.sh <project-name> <absolute-path-to-code-dir>
#
# Writes:
#   .claude/settings.json   — allowlist for cross-directory operations
#   PROJECT.md              — project paths for PM sessions

set -e

if [ $# -ne 3 ]; then
  echo "Usage: bash framework/setup.sh <project-name> <absolute-path-to-code-dir> <org/repo>"
  echo "Example: bash framework/setup.sh hometastic /Users/tim/Developer/hometastic-code Fricktastic/hometastic-code"
  exit 1
fi

PROJECT_NAME="$1"
CODE_DIR="$2"
ISSUE_REPO="$3"
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
      "Bash(*)",
      "Read(${CODE_DIR}/**)",
      "Edit(${CODE_DIR}/**)",
      "Write(${CODE_DIR}/**)",
      "Read(${PM_DIR}/**)",
      "Edit(${PM_DIR}/**)",
      "Write(${PM_DIR}/**)"
    ],
    "deny": [
      "mcp__sosumi__fetchAppleDocumentation",
      "mcp__sosumi__fetchAppleVideoTranscript",
      "mcp__sosumi__fetchExternalDocumentation",
      "mcp__sosumi__searchAppleDocumentation",
      "mcp__claude_ai_Figma__add_code_connect_map",
      "mcp__claude_ai_Figma__create_new_file",
      "mcp__claude_ai_Figma__generate_diagram",
      "mcp__claude_ai_Figma__get_code_connect_map",
      "mcp__claude_ai_Figma__get_code_connect_suggestions",
      "mcp__claude_ai_Figma__get_context_for_code_connect",
      "mcp__claude_ai_Figma__get_design_context",
      "mcp__claude_ai_Figma__get_figjam",
      "mcp__claude_ai_Figma__get_libraries",
      "mcp__claude_ai_Figma__get_metadata",
      "mcp__claude_ai_Figma__get_screenshot",
      "mcp__claude_ai_Figma__get_variable_defs",
      "mcp__claude_ai_Figma__search_design_system",
      "mcp__claude_ai_Figma__send_code_connect_mappings",
      "mcp__claude_ai_Figma__upload_assets",
      "mcp__claude_ai_Figma__use_figma",
      "mcp__claude_ai_Figma__whoami"
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
| Issue repo | \`${ISSUE_REPO}\` |

## Notes

<!-- Add any project-specific notes here for future PM sessions. -->
EOF

echo "✓ Wrote PROJECT.md"
echo ""
echo "Setup complete. Start the PM with: claude"
