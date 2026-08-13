#!/bin/zsh
set -euo pipefail

ROOK_USER_HOME="${HOME:?A user home directory is required}"
INSTALL_ROOT="${ROOK_INSTALL_ROOT:-$ROOK_USER_HOME/Applications}"
TARGET_APP="$INSTALL_ROOT/Rook.app"
LOGIN_PLIST="$ROOK_USER_HOME/Library/LaunchAgents/com.noah.rook.login.plist"
TRASH_DIR="$ROOK_USER_HOME/.Trash/Rook-uninstall-$(date +%Y%m%d-%H%M%S)"

/usr/bin/pkill -x Rook 2>/dev/null || true
/bin/launchctl bootout "gui/$(id -u)/com.noah.rook.login" 2>/dev/null || true

mkdir -p "$TRASH_DIR"
if [[ -d "$TARGET_APP" ]]; then
  mv "$TARGET_APP" "$TRASH_DIR/Rook.app"
fi
if [[ -f "$LOGIN_PLIST" ]]; then
  mv "$LOGIN_PLIST" "$TRASH_DIR/com.noah.rook.login.plist"
fi

echo "Moved the Rook app and login item to $TRASH_DIR"
echo "Private state remains at $ROOK_USER_HOME/.codex/rook/core"
