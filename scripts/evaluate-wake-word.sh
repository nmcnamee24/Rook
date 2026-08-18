#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
exec /usr/bin/python3 "$SCRIPT_DIR/evaluate_wake_word.py" "$@"
