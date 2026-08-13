#!/usr/bin/env python3
"""Persistent, auditable approval queue for the Rook skill."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
import tempfile
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Iterator


VERSION = 1
VALID_STATUSES = {"pending", "approved", "rejected", "completed", "cancelled"}


def compact_words(value: str, limit: int = 4) -> str:
    words = value.strip().split()
    return " ".join(words[:limit])


def action_label(kind: str, title: str, requested: str = "") -> str:
    if requested.strip():
        label = compact_words(requested)
    else:
        words = title.strip().split()
        lowered = kind.lower()
        if lowered == "calendar_update" and words and words[0].lower() == "move":
            subject: list[str] = []
            for word in words[1:]:
                if word.lower() in {"to", "at", "on", "from"}:
                    break
                subject.append(word)
            label = " ".join(["Move", *(subject[:2] or ["event"]), "time"])
        elif lowered == "gmail_draft" and "meeting notes" in title.lower():
            label = "Draft meeting notes"
        else:
            action = {
                "calendar_create": "Add",
                "calendar_update": "Update",
                "gmail_draft": "Draft",
                "gmail_send": "Send",
                "calendar_delete": "Delete",
            }.get(lowered, "Review")
            if words and words[0].lower() == action.lower():
                label = " ".join(words)
            else:
                label = " ".join([action, *words])
        label = compact_words(label)
    if not label:
        label = "Review action"
    return label[0].upper() + label[1:]


def item_label(item: dict[str, Any]) -> str:
    return action_label(item.get("kind", ""), item.get("title", ""), item.get("label", ""))


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.replace(microsecond=0).isoformat()


def state_dir() -> Path:
    override = os.environ.get("ROOK_STATE_DIR")
    return Path(override).expanduser() if override else Path.home() / ".codex" / "rook"


def queue_path() -> Path:
    return state_dir() / "action_queue.json"


def blank_state() -> dict[str, Any]:
    return {"version": VERSION, "next_id": 1, "items": []}


def write_atomic(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=".queue-", suffix=".tmp", delete=False
    ) as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
        temporary = Path(handle.name)
    os.replace(temporary, path)


@contextmanager
def locked_state(mutating: bool = False) -> Iterator[dict[str, Any]]:
    directory = state_dir()
    directory.mkdir(parents=True, exist_ok=True)
    lock_path = directory / ".queue.lock"
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX if mutating else fcntl.LOCK_SH)
        path = queue_path()
        if path.exists():
            with path.open(encoding="utf-8") as handle:
                data = json.load(handle)
        else:
            data = blank_state()
        if data.get("version") != VERSION or not isinstance(data.get("items"), list):
            raise ValueError(f"Unsupported or invalid queue at {path}")
        yield data
        if mutating:
            write_atomic(path, data)


def effective_status(item: dict[str, Any], now: datetime | None = None) -> str:
    status = item["status"]
    if status != "pending":
        return status
    expires_at = item.get("expires_at")
    if expires_at and datetime.fromisoformat(expires_at) <= (now or utc_now()):
        return "expired"
    return status


def filtered_items(data: dict[str, Any], status: str) -> list[dict[str, Any]]:
    items = [item for item in data["items"] if status == "all" or effective_status(item) == status]
    return sorted(items, key=lambda item: (item["created_at"], item["id"]))


def resolve(data: dict[str, Any], selector: str, allowed: set[str]) -> dict[str, Any]:
    normalized = selector.strip().upper()
    for item in data["items"]:
        if item["id"].upper() == normalized:
            if effective_status(item) not in allowed:
                raise ValueError(f"{item['id']} has status {effective_status(item)}, expected {', '.join(sorted(allowed))}")
            return item
    if selector.isdigit():
        candidates = [item for item in filtered_items(data, "pending") if effective_status(item) in allowed]
        position = int(selector)
        if 1 <= position <= len(candidates):
            return candidates[position - 1]
    label_selector = " ".join(selector.casefold().split())
    label_matches = [
        item
        for item in data["items"]
        if effective_status(item) in allowed
        and " ".join(item_label(item).casefold().split()) == label_selector
    ]
    if len(label_matches) == 1:
        return label_matches[0]
    if len(label_matches) > 1:
        raise ValueError(f"Multiple queue items use the label: {selector}")
    raise ValueError(f"No matching queue item: {selector}")


def printable(item: dict[str, Any], position: int | None = None) -> str:
    prefix = f"{position}. " if position is not None else ""
    return f"{prefix}{item_label(item)} [{effective_status(item)}] — {item['proposed_action']}"


def cmd_init(_: argparse.Namespace) -> int:
    with locked_state(mutating=True) as data:
        count = len(data["items"])
    print(json.dumps({"ok": True, "path": str(queue_path()), "items": count}))
    return 0


def cmd_add(args: argparse.Namespace) -> int:
    try:
        payload = json.loads(args.payload_json)
    except json.JSONDecodeError as error:
        raise ValueError(f"Invalid --payload-json: {error}") from error
    if not isinstance(payload, dict):
        raise ValueError("--payload-json must decode to a JSON object")
    now = utc_now()
    with locked_state(mutating=True) as data:
        number = int(data["next_id"])
        item = {
            "id": f"RQ-{number:04d}",
            "kind": args.kind,
            "label": action_label(args.kind, args.title, args.label),
            "title": args.title.strip(),
            "details": args.details.strip(),
            "proposed_action": args.proposed_action.strip(),
            "risk": args.risk,
            "sources": args.source or [],
            "payload": payload,
            "status": "pending",
            "created_at": iso(now),
            "expires_at": iso(now + timedelta(hours=args.expires_hours)),
            "history": [{"status": "pending", "at": iso(now), "note": "Queued"}],
        }
        data["items"].append(item)
        data["next_id"] = number + 1
    print(json.dumps(item, indent=2, sort_keys=True))
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    with locked_state() as data:
        items = filtered_items(data, args.status)
    if args.json:
        print(json.dumps(items, indent=2, sort_keys=True))
    elif not items:
        print(f"No {args.status} Rook queue items.")
    else:
        for position, item in enumerate(items, start=1):
            print(printable(item, position))
            if args.verbose and item.get("details"):
                print(f"   {item['details']}")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    with locked_state() as data:
        item = resolve(data, args.selector, VALID_STATUSES | {"expired"})
    print(json.dumps(item, indent=2, sort_keys=True) if args.json else printable(item))
    if not args.json:
        print(item.get("details", ""))
    return 0


def transition(args: argparse.Namespace, from_statuses: set[str], to_status: str, note_field: str) -> int:
    with locked_state(mutating=True) as data:
        item = resolve(data, args.selector, from_statuses)
        now = iso(utc_now())
        item["status"] = to_status
        item[f"{to_status}_at"] = now
        note = getattr(args, note_field)
        item["history"].append({"status": to_status, "at": now, "note": note})
        if to_status == "completed":
            item["result"] = note
    print(json.dumps({"ok": True, "id": item["id"], "status": to_status, "title": item["title"]}))
    return 0


def cmd_doctor(_: argparse.Namespace) -> int:
    with locked_state() as data:
        ids = [item.get("id") for item in data["items"]]
        problems: list[str] = []
        if len(ids) != len(set(ids)):
            problems.append("duplicate item IDs")
        for item in data["items"]:
            if item.get("status") not in VALID_STATUSES:
                problems.append(f"invalid status for {item.get('id')}")
            label = item_label(item)
            if not label or len(label.split()) > 4:
                problems.append(f"invalid label for {item.get('id')}")
    result = {"ok": not problems, "path": str(queue_path()), "items": len(ids), "problems": problems}
    print(json.dumps(result))
    return 0 if not problems else 1


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Manage Rook's persistent approval queue")
    commands = root.add_subparsers(dest="command", required=True)

    init = commands.add_parser("init")
    init.set_defaults(func=cmd_init)

    add = commands.add_parser("add")
    add.add_argument("--kind", required=True)
    add.add_argument("--label", default="")
    add.add_argument("--title", required=True)
    add.add_argument("--details", default="")
    add.add_argument("--proposed-action", required=True)
    add.add_argument("--risk", choices=["low", "medium", "high"], default="medium")
    add.add_argument("--source", action="append")
    add.add_argument("--payload-json", default="{}")
    add.add_argument("--expires-hours", type=int, default=72)
    add.set_defaults(func=cmd_add)

    listing = commands.add_parser("list")
    listing.add_argument("--status", choices=sorted(VALID_STATUSES | {"expired", "all"}), default="pending")
    listing.add_argument("--json", action="store_true")
    listing.add_argument("--verbose", action="store_true")
    listing.set_defaults(func=cmd_list)

    show = commands.add_parser("show")
    show.add_argument("selector")
    show.add_argument("--json", action="store_true")
    show.set_defaults(func=cmd_show)

    approve = commands.add_parser("approve")
    approve.add_argument("selector")
    approve.add_argument("--note", required=True)
    approve.set_defaults(func=lambda args: transition(args, {"pending"}, "approved", "note"))

    reject = commands.add_parser("reject")
    reject.add_argument("selector")
    reject.add_argument("--note", required=True)
    reject.set_defaults(func=lambda args: transition(args, {"pending"}, "rejected", "note"))

    complete = commands.add_parser("complete")
    complete.add_argument("selector")
    complete.add_argument("--result", required=True)
    complete.set_defaults(func=lambda args: transition(args, {"approved"}, "completed", "result"))

    cancel = commands.add_parser("cancel")
    cancel.add_argument("selector")
    cancel.add_argument("--note", required=True)
    cancel.set_defaults(func=lambda args: transition(args, {"approved"}, "cancelled", "note"))

    doctor = commands.add_parser("doctor")
    doctor.set_defaults(func=cmd_doctor)
    return root


def main() -> int:
    try:
        args = parser().parse_args()
        if getattr(args, "expires_hours", 1) <= 0:
            raise ValueError("--expires-hours must be positive")
        return int(args.func(args))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
