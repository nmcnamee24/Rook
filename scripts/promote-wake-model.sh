#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
ROOK_USER_HOME="${HOME:?A user home directory is required}"
WAKE_DIR="${ROOK_WAKE_DIR:-$ROOK_USER_HOME/.codex/rook/wake}"
CANDIDATE="${1:-$PROJECT_DIR/.artifacts.noindex/wake/rook-candidate.onnx}"
HELPER="$PROJECT_DIR/.build/release/RookWakeTool"

if [[ ! -f "$CANDIDATE" ]]; then
  print -u2 "Candidate wake model is missing: $CANDIDATE"
  exit 2
fi

cd "$PROJECT_DIR"
swift build -c release --product RookWakeTool >/dev/null
"$HELPER" probe "$CANDIDATE" 68 >/dev/null

mkdir -p "$PROJECT_DIR/.artifacts.noindex/wake" "$WAKE_DIR"
chmod 700 "$WAKE_DIR"
REPORT="$(/usr/bin/mktemp "$PROJECT_DIR/.artifacts.noindex/wake/.validation.XXXXXX.json")"
trap '/bin/rm -f "$REPORT"' EXIT

"$SCRIPT_DIR/evaluate-wake-word.sh" \
  --helper "$HELPER" \
  --model "$CANDIDATE" \
  --operating-point 68 \
  --json-output "$REPORT" >/dev/null

STAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
if [[ -f "$WAKE_DIR/rook.onnx" ]]; then
  /bin/cp -p "$WAKE_DIR/rook.onnx" "$WAKE_DIR/rook.onnx.backup-$STAMP"
fi
if [[ -f "$WAKE_DIR/rook.validation.json" ]]; then
  /bin/cp -p "$WAKE_DIR/rook.validation.json" "$WAKE_DIR/rook.validation.json.backup-$STAMP"
fi

/bin/cp -p "$CANDIDATE" "$WAKE_DIR/rook.onnx"
/bin/cp -p "$REPORT" "$WAKE_DIR/rook.validation.json"
chmod 600 "$WAKE_DIR/rook.onnx" "$WAKE_DIR/rook.validation.json"
print "Validated Rook wake model promoted to $WAKE_DIR/rook.onnx"
print "Run make install to restart Rook with the local model."
