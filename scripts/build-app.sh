#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_DIR="$PROJECT_DIR/.artifacts.noindex/Rook.app"
STAGE_ROOT="$(/usr/bin/mktemp -d -t rook-app-build)"
STAGED_APP="$STAGE_ROOT/Rook.app"
trap '/bin/rm -rf "$STAGE_ROOT"' EXIT

SIGNING_IDENTITY="${ROOK_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | /usr/bin/head -1)"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="-"
fi

cd "$PROJECT_DIR"
swift build -c release

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$PROJECT_DIR/.build/release/RookCore" "$STAGED_APP/Contents/MacOS/Rook"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/kokoro_worker.py" "$STAGED_APP/Contents/Resources/kokoro_worker.py"
chmod 755 "$STAGED_APP/Contents/MacOS/Rook"
chmod 644 "$STAGED_APP/Contents/Resources/kokoro_worker.py"
/usr/bin/xattr -cr "$STAGED_APP"
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$STAGED_APP"

/bin/rm -rf "$APP_DIR"
/usr/bin/ditto "$STAGED_APP" "$APP_DIR"

echo "$APP_DIR"
