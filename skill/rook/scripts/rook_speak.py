#!/usr/bin/env python3
"""Speak a short, non-sensitive Rook response with local neural TTS."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile


DEFAULT_TTS_DIR = Path.home() / ".codex" / "rook" / "tts"


def speak_with_kokoro(text: str, voice: str, speed: float, tts_dir: Path) -> bool:
    python = tts_dir / ".venv" / "bin" / "python"
    model = tts_dir / "kokoro-v1.0.onnx"
    voices = tts_dir / "voices-v1.0.bin"
    if not all(path.exists() for path in (python, model, voices)):
        return False

    if os.environ.get("ROOK_TTS_REEXEC") != "1":
        environment = os.environ.copy()
        environment["ROOK_TTS_REEXEC"] = "1"
        completed = subprocess.run([str(python), __file__, *sys.argv[1:]], env=environment, check=False)
        return completed.returncode == 0

    try:
        import soundfile as sf
        from kokoro_onnx import Kokoro

        engine = Kokoro(str(model), str(voices))
        samples, sample_rate = engine.create(
            text,
            voice=voice,
            speed=speed,
            lang="en-gb",
        )
        with tempfile.NamedTemporaryFile(prefix="rook-", suffix=".wav", delete=False) as temporary:
            audio_path = Path(temporary.name)
        try:
            sf.write(audio_path, samples, sample_rate, format="WAV")
            subprocess.run(["/usr/bin/afplay", str(audio_path)], check=True)
        finally:
            audio_path.unlink(missing_ok=True)
        return True
    except Exception as error:
        print(f"Rook neural voice unavailable: {error}", file=sys.stderr)
        return False


def speak_with_macos(text: str, voice: str, rate: int) -> None:
    subprocess.run(["/usr/bin/say", "-v", voice, "-r", str(rate), text], check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Speak a concise Rook response")
    parser.add_argument("--text", help="Text to speak; reads stdin when omitted")
    parser.add_argument("--voice", default="bm_daniel", help="Kokoro voice preset")
    parser.add_argument("--speed", type=float, default=0.96, help="Kokoro speech speed")
    parser.add_argument("--fallback-voice", default="Daniel", help="macOS voice used if Kokoro fails")
    parser.add_argument("--rate", type=int, default=195, help="macOS fallback speaking rate")
    parser.add_argument("--max-chars", type=int, default=420)
    parser.add_argument("--tts-dir", type=Path, default=DEFAULT_TTS_DIR)
    args = parser.parse_args()

    text = (args.text if args.text is not None else sys.stdin.read()).strip()
    if not text:
        parser.error("No text supplied")
    if len(text) > args.max_chars:
        text = text[: args.max_chars].rsplit(" ", 1)[0].rstrip(" ,;:-") + "."
    if not speak_with_kokoro(text, args.voice, args.speed, args.tts_dir.expanduser()):
        speak_with_macos(text, args.fallback_voice, args.rate)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
