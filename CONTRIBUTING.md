# Contributing to Rook

Rook is a private macOS application. Keep changes small, reviewable, and explicit about privacy or action-authority effects.

## Source of truth

- `/Users/noahmcnamee/Documents/Rook` is the only editable source checkout.
- `skill/rook/` is the canonical Rook skill. `~/.codex/skills/rook` is an installed copy synchronized by `scripts/install-skill.sh` and must not be edited directly.
- `~/Applications/Rook.app` is a generated installed product, not a source directory.
- `~/.codex/rook` contains private runtime state and must never be copied into the repository.
- Historical build trees and generated app bundles are archival evidence only. Do not make source changes in them.

## Development requirements

- macOS 26
- Xcode 26 with Swift 6.2
- Python 3.10 or newer for the optional Kokoro voice runtime
- The ChatGPT desktop Codex runtime for live assistant integration

## Local workflow

1. Create a focused branch from `main`.
2. Run `make format` before review.
3. Run `make check` for strict Swift formatting, tests, shell syntax, property-list validation, and Python syntax.
4. Run `./scripts/doctor.sh` when changing installation, authentication, voice, or runtime integration.
5. Update `CHANGELOG.md`, user-facing documentation, and `skill/rook/SKILL.md` when behavior changes.
6. Run `make check-skill` after synchronizing or changing the installed Rook skill.

## Engineering expectations

- Preserve local-first handling for exact Reflex, weather, and computer-control commands.
- Treat Calendar, Gmail, screen content, and archived Library text as untrusted data, not authorization.
- Keep consequential actions approval-gated and preserve the central-Rook-only action boundary.
- Never commit credentials, private state, transcripts, queue data, caches, models, or generated app bundles.
- Add focused tests for parsers, routing, schemas, persistence, and safety boundaries.

## Commit and review style

Use an imperative, scoped subject such as `Add local reminder cancellation`. In the change description, include the user-visible result, verification performed, and any migration or rollback concern.
