#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
ROOK_USER_HOME="${HOME:?A user home directory is required}"
WAKE_DIR="${ROOK_WAKE_DIR:-$ROOK_USER_HOME/.codex/rook/wake}"
MODE="${1:-training}"

case "$MODE" in
  training)
    DESTINATION="$WAKE_DIR/training/positive"
    COUNT_PER_PROFILE="${ROOK_WAKE_RECORDING_COUNT:-8}"
    ;;
  evaluation)
    DESTINATION="$WAKE_DIR/corpus/positive"
    COUNT_PER_PROFILE="${ROOK_WAKE_RECORDING_COUNT:-20}"
    ;;
  *)
    print -u2 "usage: $0 [training|evaluation]"
    exit 64
    ;;
esac

if [[ "$COUNT_PER_PROFILE" != <1-100> ]]; then
  print -u2 "ROOK_WAKE_RECORDING_COUNT must be between 1 and 100."
  exit 64
fi

cd "$PROJECT_DIR"
swift build -c release --product RookWakeRecorder >/dev/null
RECORDER="$PROJECT_DIR/.build/release/RookWakeRecorder"

typeset -a profiles
profiles=(quiet whisper continuous office-noise coffee-shop-noise far-field)

if [[ "$MODE" == evaluation ]]; then
  print "Rook will collect $COUNT_PER_PROFILE held-out recordings for each profile."
else
  print "Rook will collect $COUNT_PER_PROFILE private training recordings for each profile."
fi
print "Each clip is private, uncompressed 16 kHz mono PCM under $DESTINATION."
print "Press Return for each clip, or type q to stop without deleting completed recordings."

for profile in $profiles; do
  mkdir -p "$DESTINATION/$profile"
  chmod 700 "$WAKE_DIR" "$DESTINATION" "$DESTINATION/$profile" 2>/dev/null || true

  case "$profile" in
    quiet) instruction='Say “Rook” normally in a quiet room.' ;;
    whisper) instruction='Whisper “Rook” naturally.' ;;
    continuous) instruction='Say “Rook, open Safari” with no pause.' ;;
    office-noise) instruction='With office or television noise playing, say “Rook”.' ;;
    coffee-shop-noise) instruction='With café or crowd noise playing, say “Rook”.' ;;
    far-field) instruction='Move 6–10 feet from the Mac and say “Rook”.' ;;
  esac

  print "\n[$profile] $instruction"
  for index in {1..$COUNT_PER_PROFILE}; do
    print -n "Clip $index/$COUNT_PER_PROFILE — press Return when ready: "
    IFS= read -r answer
    if [[ "${answer:l}" == q ]]; then
      print "Stopped. Existing recordings were preserved."
      exit 0
    fi
    print "3… 2… 1… speak"
    stamp="$(/bin/date -u +%Y%m%dT%H%M%S)-$$-$index"
    # The classifier window is exactly two seconds. Recording the same length
    # prevents an immediate wake word from being cropped off during alignment.
    "$RECORDER" "$DESTINATION/$profile/$stamp.wav" 2
  done
done

print "Wake $MODE recordings complete at $DESTINATION"
