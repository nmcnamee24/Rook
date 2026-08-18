#!/usr/bin/env python3
"""Evaluate Rook's owned ONNX wake model against an explicit PCM WAV corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import wave
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from datetime import datetime, timezone


DEFAULT_PROFILES = (
    "quiet",
    "whisper",
    "continuous",
    "office-noise",
    "coffee-shop-noise",
    "far-field",
)


@dataclass(frozen=True)
class FileResult:
    path: str
    profile: str
    expected_wake: bool
    detections: int
    duration_seconds: float


def parse_arguments() -> argparse.Namespace:
    home = Path.home()
    parser = argparse.ArgumentParser(
        description=(
            "Run Rook's local wake helper over a positive/negative WAV corpus. "
            "Audio is read locally and streamed only to the local helper."
        )
    )
    parser.add_argument(
        "--corpus",
        type=Path,
        default=home / ".codex/rook/wake/corpus",
        help="Corpus containing positive/<profile>/*.wav and negative/**/*.wav",
    )
    parser.add_argument(
        "--helper",
        type=Path,
        default=home / ".codex/rook/wake/rook-livekit-wake",
    )
    parser.add_argument(
        "--model",
        type=Path,
        default=home / ".codex/rook/wake/rook.onnx",
    )
    parser.add_argument("--operating-point", type=int, default=68)
    parser.add_argument("--minimum-positive-samples", type=int, default=20)
    parser.add_argument("--minimum-negative-hours", type=float, default=24.0)
    parser.add_argument("--minimum-recall", type=float, default=0.95)
    parser.add_argument("--maximum-false-activations-per-24h", type=float, default=1.0)
    parser.add_argument(
        "--required-profile",
        action="append",
        dest="required_profiles",
        help="Required positive profile; repeat to override Rook's default profile set",
    )
    parser.add_argument("--json-output", type=Path)
    parser.add_argument(
        "--advisory",
        action="store_true",
        help="Report incomplete/failed acceptance gates without returning a failing exit code",
    )
    return parser.parse_args()


def read_pcm(path: Path) -> tuple[bytes, float]:
    try:
        with wave.open(str(path), "rb") as audio:
            channels = audio.getnchannels()
            sample_width = audio.getsampwidth()
            sample_rate = audio.getframerate()
            frame_count = audio.getnframes()
            compression = audio.getcomptype()
            if (channels, sample_width, sample_rate, compression) != (1, 2, 16_000, "NONE"):
                raise ValueError(
                    "must be uncompressed 16 kHz mono 16-bit PCM WAV "
                    f"(found channels={channels}, width={sample_width}, rate={sample_rate}, "
                    f"compression={compression})"
                )
            return audio.readframes(frame_count), frame_count / sample_rate
    except wave.Error as error:
        raise ValueError(f"is not a readable PCM WAV: {error}") from error


def detect(
    helper: Path,
    model: Path,
    operating_point: int,
    pcm: bytes,
    duration_seconds: float,
) -> int:
    # Evaluation runs much faster than real time, but a one-hour ambient file
    # still contains 45,000 inference strides. Keep short-file failures bounded
    # while giving long negative recordings enough proportional headroom.
    timeout_seconds = max(30.0, duration_seconds / 10.0 + 15.0)
    try:
        result = subprocess.run(
            [str(helper), str(model), str(operating_point)],
            input=pcm,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            f"wake helper exceeded {timeout_seconds:.0f} seconds for one file"
        ) from error
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"wake helper failed with status {result.returncode}: {detail}")
    lines = result.stdout.decode("utf-8", errors="replace").splitlines()
    if "READY" not in lines:
        raise RuntimeError("wake helper did not emit READY")
    return sum(line.startswith("WAKE\t") for line in lines)


def corpus_files(corpus: Path) -> list[tuple[Path, str, bool]]:
    files: list[tuple[Path, str, bool]] = []
    positive_root = corpus / "positive"
    if positive_root.is_dir():
        for path in sorted(positive_root.rglob("*.wav")):
            relative = path.relative_to(positive_root)
            profile = relative.parts[0] if len(relative.parts) > 1 else "unprofiled"
            files.append((path, profile, True))
    negative_root = corpus / "negative"
    if negative_root.is_dir():
        files.extend((path, "negative", False) for path in sorted(negative_root.rglob("*.wav")))
    return files


def main() -> int:
    args = parse_arguments()
    required_profiles = tuple(args.required_profiles or DEFAULT_PROFILES)
    if not args.helper.is_file() or not args.helper.stat().st_mode & 0o111:
        print(f"Wake helper is missing or not executable: {args.helper}", file=sys.stderr)
        return 2
    if not args.model.is_file():
        print(f"Personalized wake model is missing: {args.model}", file=sys.stderr)
        return 2

    files = corpus_files(args.corpus)
    if not files:
        print(
            f"No WAV files found under {args.corpus}/positive or {args.corpus}/negative",
            file=sys.stderr,
        )
        return 2

    results: list[FileResult] = []
    for path, profile, expected_wake in files:
        try:
            pcm, duration = read_pcm(path)
            detections = detect(
                args.helper,
                args.model,
                args.operating_point,
                pcm,
                duration,
            )
        except (OSError, RuntimeError, ValueError) as error:
            print(f"{path}: {error}", file=sys.stderr)
            return 2
        results.append(
            FileResult(
                path=str(path),
                profile=profile,
                expected_wake=expected_wake,
                detections=detections,
                duration_seconds=duration,
            )
        )

    positives: dict[str, list[FileResult]] = defaultdict(list)
    negatives: list[FileResult] = []
    for result in results:
        if result.expected_wake:
            positives[result.profile].append(result)
        else:
            negatives.append(result)

    profile_metrics: dict[str, dict[str, float | int | bool]] = {}
    gates: list[dict[str, str | bool]] = []
    for profile in required_profiles:
        samples = positives.get(profile, [])
        detected = sum(item.detections > 0 for item in samples)
        recall = detected / len(samples) if samples else 0.0
        profile_metrics[profile] = {
            "samples": len(samples),
            "detected": detected,
            "recall": recall,
        }
        enough_samples = len(samples) >= args.minimum_positive_samples
        enough_recall = recall >= args.minimum_recall
        gates.extend(
            [
                {
                    "name": f"{profile} sample count",
                    "passed": enough_samples,
                    "detail": f"{len(samples)} >= {args.minimum_positive_samples}",
                },
                {
                    "name": f"{profile} recall",
                    "passed": enough_recall,
                    "detail": f"{recall:.3f} >= {args.minimum_recall:.3f}",
                },
            ]
        )

    negative_seconds = sum(item.duration_seconds for item in negatives)
    negative_hours = negative_seconds / 3_600
    false_activations = sum(item.detections for item in negatives)
    false_per_24h = false_activations / negative_hours * 24 if negative_hours else None
    gates.extend(
        [
            {
                "name": "negative corpus duration",
                "passed": negative_hours >= args.minimum_negative_hours,
                "detail": f"{negative_hours:.3f} >= {args.minimum_negative_hours:.3f} hours",
            },
            {
                "name": "false activations",
                "passed": (
                    false_per_24h is not None
                    and false_per_24h <= args.maximum_false_activations_per_24h
                ),
                "detail": (
                    (
                        f"{false_per_24h:.3f} <= "
                        f"{args.maximum_false_activations_per_24h:.3f} per 24 hours"
                    )
                    if false_per_24h is not None
                    else "unavailable until the negative corpus contains audio"
                ),
            },
        ]
    )
    passed = all(bool(gate["passed"]) for gate in gates)
    report = {
        "passed": passed,
        "engine": "livekit-wakeword",
        "evaluated_at": datetime.now(timezone.utc).isoformat(),
        "corpus": str(args.corpus),
        "helper": str(args.helper),
        "model": str(args.model),
        "model_sha256": hashlib.sha256(args.model.read_bytes()).hexdigest(),
        "operating_point": args.operating_point,
        "profiles": profile_metrics,
        "negative": {
            "files": len(negatives),
            "hours": negative_hours,
            "false_activations": false_activations,
            "false_activations_per_24h": false_per_24h,
        },
        "gates": gates,
        "files": [asdict(item) for item in results],
    }

    rendered = json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(rendered, encoding="utf-8")
    sys.stdout.write(rendered)
    return 0 if passed or args.advisory else 1


if __name__ == "__main__":
    raise SystemExit(main())
