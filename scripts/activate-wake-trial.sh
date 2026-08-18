#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
ROOK_USER_HOME="${HOME:?A user home directory is required}"
WAKE_DIR="${ROOK_WAKE_DIR:-$ROOK_USER_HOME/.codex/rook/wake}"
CANDIDATE="${1:-$PROJECT_DIR/.artifacts.noindex/wake/rook-candidate.onnx}"
HELPER="$PROJECT_DIR/.build/release/RookWakeTool"
MODEL_STAGE="$WAKE_DIR/.rook.onnx.trial.$$"
MANIFEST_STAGE="$WAKE_DIR/.rook.validation.json.trial.$$"

cleanup() {
  /bin/rm -f "$MODEL_STAGE" "$MANIFEST_STAGE"
}
trap cleanup EXIT

if [[ ! -f "$CANDIDATE" ]]; then
  print -u2 "Candidate wake model is missing: $CANDIDATE"
  exit 2
fi

cd "$PROJECT_DIR"
swift build -c release --product RookWakeTool >/dev/null
"$HELPER" probe "$CANDIDATE" 68 >/dev/null

mkdir -p "$WAKE_DIR"
chmod 700 "$WAKE_DIR"
/bin/cp -p "$CANDIDATE" "$MODEL_STAGE"
chmod 600 "$MODEL_STAGE"

MODEL_SHA="$(/usr/bin/shasum -a 256 "$MODEL_STAGE" | /usr/bin/awk '{print $1}')"
ACTIVATED_AT="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
/usr/bin/printf '%s\n' \
  '{' \
  '  "passed": false,' \
  '  "trial_enabled": true,' \
  "  \"model_sha256\": \"$MODEL_SHA\"," \
  '  "operating_point": 68,' \
  "  \"activated_at\": \"$ACTIVATED_AT\"," \
  '  "source": "rook-candidate.onnx"' \
  '}' > "$MANIFEST_STAGE"
chmod 600 "$MANIFEST_STAGE"

STAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
if [[ -f "$WAKE_DIR/rook.onnx" ]]; then
  /bin/cp -p "$WAKE_DIR/rook.onnx" "$WAKE_DIR/rook.onnx.backup-$STAMP"
fi
if [[ -f "$WAKE_DIR/rook.validation.json" ]]; then
  /bin/cp -p "$WAKE_DIR/rook.validation.json" \
    "$WAKE_DIR/rook.validation.json.backup-$STAMP"
fi

/bin/mv -f "$MODEL_STAGE" "$WAKE_DIR/rook.onnx"
/bin/mv -f "$MANIFEST_STAGE" "$WAKE_DIR/rook.validation.json"

print "Unvalidated Rook wake trial activated at $WAKE_DIR/rook.onnx"
print "The manifest is SHA-bound and remains marked passed=false."
print "Run make install to restart Rook with the local candidate."
