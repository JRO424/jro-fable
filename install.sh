#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="jro-fable"
SKILL_DIR="${HOME}/.claude/skills/${SKILL_NAME}"
CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing ${SKILL_NAME}..."

# Create skills directory if needed
mkdir -p "$(dirname "$SKILL_DIR")"

# Copy skill files
if [ "$SCRIPT_DIR" != "$SKILL_DIR" ]; then
  cp -r "$SCRIPT_DIR" "$SKILL_DIR"
  echo "  Copied to ${SKILL_DIR}"
else
  echo "  Already in place at ${SKILL_DIR}"
fi

# Add to CLAUDE.md if not already referenced
if [ -f "$CLAUDE_MD" ]; then
  if grep -q "${SKILL_NAME}" "$CLAUDE_MD" 2>/dev/null; then
    echo "  CLAUDE.md already references ${SKILL_NAME} — skipped."
  else
    cat >> "$CLAUDE_MD" <<EOF

# ${SKILL_NAME}
- **${SKILL_NAME}** (\`~/.claude/skills/${SKILL_NAME}/SKILL.md\`) - Fable cost optimizer
When the user types \`/${SKILL_NAME}\`, invoke the Skill tool with \`skill: "${SKILL_NAME}"\` before doing anything else.
EOF
    echo "  Added ${SKILL_NAME} to ${CLAUDE_MD}"
  fi
else
  echo "  Warning: ${CLAUDE_MD} not found. Add the skill reference manually."
  echo "  See README.md for the snippet to add."
fi

echo ""
echo "Done! Use /jro-fable in Claude Code to activate."
