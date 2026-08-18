#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
ROOK_USER_HOME="${HOME:?A user home directory is required}"
WAKE_DIR="${ROOK_WAKE_DIR:-$ROOK_USER_HOME/.codex/rook/wake}"
DURATION_SECONDS="${1:-3600}"

if [[ "$DURATION_SECONDS" != <1-86400> ]]; then
  print -u2 "usage: $0 [duration-seconds, 1..86400]"
  exit 64
fi

cd "$PROJECT_DIR"
swift build -c release --product RookWakeRecorder >/dev/null
DESTINATION="$WAKE_DIR/corpus/negative"
mkdir -p "$DESTINATION"
chmod 700 "$WAKE_DIR" "$WAKE_DIR/corpus" "$DESTINATION" 2>/dev/null || true
OUTPUT="$DESTINATION/ambient-$(/bin/date -u +%Y%m%dT%H%M%SZ)-${DURATION_SECONDS}s.wav"

print "Recording $DURATION_SECONDS seconds of ordinary ambient audio."
print "Do not intentionally say the wake word. Audio remains at $OUTPUT."
"$PROJECT_DIR/.build/release/RookWakeRecorder" "$OUTPUT" "$DURATION_SECONDS"
