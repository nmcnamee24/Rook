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
swift build -c release --product RookCore
swift build -c release --product RookWakeTool

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources/Licenses"
cp "$PROJECT_DIR/.build/release/RookCore" "$STAGED_APP/Contents/MacOS/Rook"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
PUBLIC_SPOTIFY_CLIENT_ID="${ROOK_SPOTIFY_CLIENT_ID:-}"
if [[ -n "$PUBLIC_SPOTIFY_CLIENT_ID" ]]; then
  if [[ ! "$PUBLIC_SPOTIFY_CLIENT_ID" =~ '^[[:alnum:]]{20,}$' ]]; then
    echo "ROOK_SPOTIFY_CLIENT_ID must be a public Spotify app Client ID." >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :RookSpotifyClientID $PUBLIC_SPOTIFY_CLIENT_ID" \
    "$STAGED_APP/Contents/Info.plist"
fi
cp "$PROJECT_DIR/Resources/kokoro_worker.py" "$STAGED_APP/Contents/Resources/kokoro_worker.py"
cp "$PROJECT_DIR/.build/release/RookWakeTool" \
  "$STAGED_APP/Contents/Resources/rook-livekit-wake"
/usr/bin/ditto "$PROJECT_DIR/.build/release/LiveKitWakeWord_LiveKitWakeWord.bundle" \
  "$STAGED_APP/Contents/Resources/LiveKitWakeWord_LiveKitWakeWord.bundle"
/bin/cp "$PROJECT_DIR/.build/checkouts/livekit-wakeword/LICENSE" \
  "$STAGED_APP/Contents/Resources/Licenses/LiveKitWakeWord-LICENSE.txt"
/bin/cp "$PROJECT_DIR/.build/checkouts/onnxruntime-swift-package-manager/LICENSE" \
  "$STAGED_APP/Contents/Resources/Licenses/ONNXRuntime-LICENSE.txt"
/bin/cp "$PROJECT_DIR/.build/checkouts/FluidAudio/LICENSE" \
  "$STAGED_APP/Contents/Resources/Licenses/FluidAudio-LICENSE.txt"
chmod 755 "$STAGED_APP/Contents/MacOS/Rook"
chmod 755 "$STAGED_APP/Contents/Resources/rook-livekit-wake"
chmod 644 "$STAGED_APP/Contents/Resources/kokoro_worker.py"
# SwiftPM checkout resources can be read-only. Normalize only the disposable
# staged bundle so extended attributes and code signatures can be applied.
chmod -R u+rwX "$STAGED_APP"
/usr/bin/xattr -cr "$STAGED_APP"
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$STAGED_APP"

/bin/rm -rf "$APP_DIR"
/usr/bin/ditto --norsrc "$STAGED_APP" "$APP_DIR"
/usr/bin/xattr -cr "$APP_DIR"
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"

echo "$APP_DIR"
