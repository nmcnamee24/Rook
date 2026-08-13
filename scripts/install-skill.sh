#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SKILL_SOURCE="$PROJECT_DIR/skill/rook"
ROOK_USER_HOME="${HOME:?A user home directory is required}"
SKILL_TARGET="${ROOK_SKILL_DIR:-$ROOK_USER_HOME/.codex/skills/rook}"
SKILL_FILES=(
  SKILL.md
  agents/openai.yaml
  assets/rook_flow_snippets.json
  references/operating_policy.md
  scripts/rook_queue.py
  scripts/rook_speak.py
)

if [[ "${1:-}" == "--check" ]]; then
  mismatch=0
  for relative_path in "${SKILL_FILES[@]}"; do
    if [[ ! -f "$SKILL_TARGET/$relative_path" ]] || \
      ! /usr/bin/cmp -s "$SKILL_SOURCE/$relative_path" "$SKILL_TARGET/$relative_path"; then
      echo "Skill drift: $relative_path" >&2
      mismatch=1
    fi
  done
  if (( mismatch != 0 )); then
    exit 1
  fi
  echo "Installed Rook skill matches the repository."
  exit 0
fi

if [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi

mkdir -p "$SKILL_TARGET"
/usr/bin/ditto "$SKILL_SOURCE" "$SKILL_TARGET"
echo "Synchronized Rook skill to $SKILL_TARGET"
