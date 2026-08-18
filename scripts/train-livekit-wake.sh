#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
PINNED_COMMIT="95448a7559c453fcd87645bd67b247ffb45f85b0"
SOURCE_DIR="$PROJECT_DIR/.artifacts.noindex/livekit-wakeword-$PINNED_COMMIT"
VENV_DIR="$PROJECT_DIR/.artifacts.noindex/livekit-wakeword-venv-$PINNED_COMMIT"
COMPATIBILITY_PATCH="$PROJECT_DIR/WakeModel/livekit-95448-session-options.patch"
ARTIFACT_DIR="$PROJECT_DIR/.artifacts.noindex/wake"
ROOK_USER_HOME="${HOME:?A user home directory is required}"
WAKE_DIR="${ROOK_WAKE_DIR:-$ROOK_USER_HOME/.codex/rook/wake}"
MODE="${1:-production}"

# The anonymous Xet transport can deadlock on token rate limits while fetching
# the many small noise clips. Plain HTTPS resumes the same Hugging Face cache
# and is slower only in theory for this corpus.
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"

case "$MODE" in
  production)
    CONFIG="$PROJECT_DIR/WakeModel/rook-production.yaml"
    MODEL_NAME="rook"
    ;;
  bootstrap)
    CONFIG="$PROJECT_DIR/WakeModel/rook-bootstrap.yaml"
    MODEL_NAME="rook_bootstrap"
    ;;
  *)
    print -u2 "usage: $0 [production|bootstrap]"
    exit 64
    ;;
esac

PYTHON_BIN="${ROOK_WAKE_PYTHON:-/opt/homebrew/bin/python3.13}"
if [[ ! -x "$PYTHON_BIN" ]]; then
  print -u2 "Python 3.13 is required at $PYTHON_BIN (or set ROOK_WAKE_PYTHON)."
  exit 2
fi
for command in git ffmpeg espeak-ng; do
  if ! command -v "$command" >/dev/null 2>&1; then
    print -u2 "$command is required. Install the missing training tools with:"
    print -u2 "  brew install ffmpeg espeak-ng"
    exit 2
  fi
done

mkdir -p "$PROJECT_DIR/.artifacts.noindex" "$ARTIFACT_DIR"
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  /usr/bin/git clone --filter=blob:none --no-checkout \
    https://github.com/livekit/livekit-wakeword.git "$SOURCE_DIR"
  /usr/bin/git -C "$SOURCE_DIR" fetch --depth 1 origin "$PINNED_COMMIT"
  /usr/bin/git -C "$SOURCE_DIR" checkout --detach "$PINNED_COMMIT"
fi
CURRENT_COMMIT="$(/usr/bin/git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$CURRENT_COMMIT" != "$PINNED_COMMIT" ]]; then
  print -u2 "Pinned LiveKit source directory is at $CURRENT_COMMIT, expected $PINNED_COMMIT."
  exit 3
fi

# Commit 95448a7 made SessionOptions mandatory in feature extraction without
# updating the two CLI call sites. Keep the runtime revision pinned and apply a
# narrow, reviewable training-only compatibility patch that restores a default.
if /usr/bin/git -C "$SOURCE_DIR" apply --check "$COMPATIBILITY_PATCH"; then
  /usr/bin/git -C "$SOURCE_DIR" apply "$COMPATIBILITY_PATCH"
elif ! /usr/bin/git -C "$SOURCE_DIR" apply --reverse --check "$COMPATIBILITY_PATCH"; then
  print -u2 "Pinned LiveKit source has unexpected local changes; cannot apply compatibility patch."
  exit 3
fi
PATCH_DIGEST="$(/usr/bin/shasum -a 256 "$COMPATIBILITY_PATCH" | /usr/bin/awk '{print $1}')"
PATCH_STAMP="$VENV_DIR/.rook-compatibility-$PATCH_DIGEST"

if [[ ! -x "$VENV_DIR/bin/livekit-wakeword" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/python" -m pip install --upgrade pip
  "$VENV_DIR/bin/python" -m pip install "${SOURCE_DIR}"'[train,eval,export]'
  /usr/bin/touch "$PATCH_STAMP"
elif [[ ! -f "$PATCH_STAMP" ]]; then
  "$VENV_DIR/bin/python" -m pip install --force-reinstall --no-deps \
    "${SOURCE_DIR}"'[train,eval,export]'
  /usr/bin/touch "$PATCH_STAMP"
fi

cd "$PROJECT_DIR"
if [[ "$MODE" == production ]]; then
  "$VENV_DIR/bin/livekit-wakeword" setup --config "$CONFIG"
else
  "$VENV_DIR/bin/livekit-wakeword" setup --config "$CONFIG" --skip-acav
fi

"$VENV_DIR/bin/livekit-wakeword" generate "$CONFIG"

OUTPUT_DIR="$PROJECT_DIR/.artifacts.noindex/wake-training/output/$MODEL_NAME"
if [[ "$MODE" == bootstrap ]]; then
  OUTPUT_DIR="$PROJECT_DIR/.artifacts.noindex/wake-training-bootstrap/output/$MODEL_NAME"
fi
PERSONAL_DIR="$WAKE_DIR/training/positive"
if [[ -d "$PERSONAL_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR/positive_train"
  # LiveKit's augmentation pipeline intentionally accepts only clip_######.wav.
  # Reserve the 900000 range for private recordings so they participate in
  # augmentation without colliding with generated examples.
  personal_index=900000
  for recording in "$PERSONAL_DIR"/**/*.wav(N); do
    copied_name="$(/usr/bin/printf 'clip_%06d.wav' "$personal_index")"
    /bin/cp -p "$recording" "$OUTPUT_DIR/positive_train/$copied_name"
    (( personal_index += 1 ))
  done
fi

"$VENV_DIR/bin/livekit-wakeword" augment "$CONFIG"
"$VENV_DIR/bin/livekit-wakeword" train "$CONFIG"
"$VENV_DIR/bin/livekit-wakeword" export "$CONFIG"
"$VENV_DIR/bin/livekit-wakeword" eval "$CONFIG"

CANDIDATE_SOURCE="$OUTPUT_DIR/$MODEL_NAME.onnx"
if [[ ! -f "$CANDIDATE_SOURCE" ]]; then
  print -u2 "Training completed without producing $CANDIDATE_SOURCE"
  exit 4
fi
if [[ -f "$ARTIFACT_DIR/rook-candidate.onnx" ]]; then
  /bin/mv "$ARTIFACT_DIR/rook-candidate.onnx" \
    "$ARTIFACT_DIR/rook-candidate.backup-$(/bin/date -u +%Y%m%dT%H%M%SZ).onnx"
fi
/bin/cp -p "$CANDIDATE_SOURCE" "$ARTIFACT_DIR/rook-candidate.onnx"
chmod 600 "$ARTIFACT_DIR/rook-candidate.onnx"
print "Candidate model created at $ARTIFACT_DIR/rook-candidate.onnx"
print "It is not active. Record the held-out corpus and run make promote-wake."
