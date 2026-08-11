#!/bin/zsh
set -euo pipefail

TARGET_APP="/Users/noahmcnamee/Applications/Rook.app"
LOGIN_PLIST="/Users/noahmcnamee/Library/LaunchAgents/com.noah.rook.login.plist"
TRASH_DIR="/Users/noahmcnamee/.Trash/Rook-uninstall-$(date +%Y%m%d-%H%M%S)"

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
echo "Private state remains at /Users/noahmcnamee/.codex/rook/core"
