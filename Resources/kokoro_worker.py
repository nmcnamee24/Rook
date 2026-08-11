#!/usr/bin/env python3
"""Long-lived, local Kokoro worker for the native Rook app."""

from __future__ import annotations

import argparse
import json
import sys
import traceback
from pathlib import Path

import soundfile as sf
from kokoro_onnx import Kokoro


def emit(payload: dict[str, object]) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--voices", required=True)
    args = parser.parse_args()

    try:
        engine = Kokoro(args.model, args.voices)
    except Exception as error:
        emit({"event": "error", "error": str(error)})
        traceback.print_exc(file=sys.stderr)
        return 1

    emit({"event": "ready"})
    for raw_line in sys.stdin:
        request: object = None
        try:
            request = json.loads(raw_line)
            identifier = str(request["id"])
            output = Path(request["output"])
            samples, sample_rate = engine.create(
                str(request["text"]),
                voice=str(request.get("voice", "bm_daniel")),
                speed=float(request.get("speed", 0.96)),
                lang="en-gb",
            )
            sf.write(output, samples, sample_rate, format="WAV")
            emit({"id": identifier, "ok": True, "output": str(output)})
        except Exception as error:
            identifier = request.get("id") if isinstance(request, dict) else None
            emit({"id": identifier, "ok": False, "error": str(error)})
            traceback.print_exc(file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
