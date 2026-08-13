#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
ROOK_USER_HOME="${HOME:?A user home directory is required}"
INSTALL_ROOT="${ROOK_INSTALL_ROOT:-$ROOK_USER_HOME/Applications}"
INSTALLED="$INSTALL_ROOT/Rook.app/Contents/MacOS/Rook"
BUILT="$PROJECT_DIR/.artifacts.noindex/Rook.app/Contents/MacOS/Rook"

if [[ -x "$INSTALLED" ]]; then
  exec "$INSTALLED" --doctor
elif [[ -x "$BUILT" ]]; then
  exec "$BUILT" --doctor
else
  exec swift run --package-path "$PROJECT_DIR" RookCore --doctor
fi
