#!/bin/zsh
set -euo pipefail

TTS_DIR="/Users/noahmcnamee/.codex/rook/tts"
MODEL="$TTS_DIR/kokoro-v1.0.onnx"
VOICES="$TTS_DIR/voices-v1.0.bin"
MODEL_SHA256="7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5"
VOICES_SHA256="bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"

if [[ -x "/opt/homebrew/bin/python3.13" ]]; then
  PYTHON="/opt/homebrew/bin/python3.13"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON="$(command -v python3)"
else
  echo "Python 3.10 or newer is required for Kokoro." >&2
  exit 1
fi

mkdir -p "$TTS_DIR"
chmod 700 "$TTS_DIR"

if [[ ! -x "$TTS_DIR/.venv/bin/python" ]]; then
  "$PYTHON" -m venv "$TTS_DIR/.venv"
fi
"$TTS_DIR/.venv/bin/python" -m pip install --quiet --upgrade pip
"$TTS_DIR/.venv/bin/python" -m pip install --quiet "kokoro-onnx==0.5.0" "soundfile>=0.13,<0.14"

download_verified() {
  local url="$1"
  local destination="$2"
  local expected="$3"
  local actual=""

  if [[ -f "$destination" ]]; then
    actual="$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{print $1}')"
  fi
  if [[ "$actual" == "$expected" ]]; then
    return
  fi

  local temporary="${destination}.download"
  /usr/bin/curl --fail --location --retry 3 "$url" --output "$temporary"
  actual="$(/usr/bin/shasum -a 256 "$temporary" | /usr/bin/awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    /bin/rm -f "$temporary"
    echo "Checksum mismatch for ${destination:t}." >&2
    exit 1
  fi
  /bin/mv "$temporary" "$destination"
}

download_verified \
  "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx" \
  "$MODEL" \
  "$MODEL_SHA256"
download_verified \
  "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin" \
  "$VOICES" \
  "$VOICES_SHA256"

chmod 600 "$MODEL" "$VOICES"
echo "Kokoro British voice is ready."
