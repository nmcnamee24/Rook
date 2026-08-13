#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SOURCE_APP="$PROJECT_DIR/.artifacts.noindex/Rook.app"
ROOK_USER_HOME="${HOME:?A user home directory is required}"
INSTALL_ROOT="${ROOK_INSTALL_ROOT:-$ROOK_USER_HOME/Applications}"
TARGET_APP="$INSTALL_ROOT/Rook.app"
TTS_DIR="${ROOK_TTS_DIR:-$ROOK_USER_HOME/.codex/rook/tts}"
LAUNCH_AGENTS_DIR="$ROOK_USER_HOME/Library/LaunchAgents"
LOGIN_PLIST="$LAUNCH_AGENTS_DIR/com.noah.rook.login.plist"

SIGNING_IDENTITY="${ROOK_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | /usr/bin/head -1)"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

if [[ ! -d "$SOURCE_APP" ]]; then
  "$SCRIPT_DIR/build-app.sh"
fi

if [[ ! -x "$TTS_DIR/.venv/bin/python" || \
      ! -f "$TTS_DIR/kokoro-v1.0.onnx" || \
      ! -f "$TTS_DIR/voices-v1.0.bin" ]]; then
  "$SCRIPT_DIR/install-kokoro.sh"
fi

mkdir -p "$INSTALL_ROOT"
"$SCRIPT_DIR/install-skill.sh"
/usr/bin/pkill -x Rook 2>/dev/null || true
/usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
/usr/bin/xattr -cr "$TARGET_APP"
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$TARGET_APP"

if [[ "${1:-}" == "--login" ]]; then
  mkdir -p "$LAUNCH_AGENTS_DIR"
  cp "$PROJECT_DIR/Resources/com.noah.rook.login.plist" "$LOGIN_PLIST"
  /usr/libexec/PlistBuddy -c "Set :ProgramArguments:2 $TARGET_APP" "$LOGIN_PLIST"
  /bin/launchctl bootout "gui/$(id -u)/com.noah.rook.login" 2>/dev/null || true
  /bin/launchctl bootstrap "gui/$(id -u)" "$LOGIN_PLIST"
fi

/usr/bin/open -a "$TARGET_APP"
echo "Installed $TARGET_APP"
