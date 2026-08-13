# Changelog

All notable Rook changes are documented here. Versions follow the app bundle's semantic `CFBundleShortVersionString`; build numbers use `CFBundleVersion`.

## [Unreleased]

### Documentation

- Added a development log for product-critical latency, wake-word, transcription, routing, and Codex-equivalence gaps, including measurable acceptance criteria and the repository stabilization order.

## [2.23] - 2026-08-13

### Added

- Added contextual action-time approval routing for `yes, send` and `send it`, including punctuation normalization, immediately preceding request binding, exact native queue context, and native completion reconciliation after verified execution.
- Added a context-aware inference preflight ahead of Reflex and every literal capability parser. It classifies continuations, retries, semantic native actions, genuine hybrids, deliberate tasks, and unresolved references before assigning execution ownership.
- Added recent-result Spotify referents from the live response and bounded Library history, allowing phrases such as `play that Spotify playlist` to resolve a uniquely selected playlist without re-searching literal pronouns.
- Added semantic Spotify playlist-purpose ranking for study, work, and focus requests using the connected user's playlist titles and descriptions, with bounded best-fit results and direct `play that` follow-ups.
- Added ordered hybrid capability plans so one request can combine central Computer Use or another direct capability with independent Scout, Forge, Scribe, Steward, or Auditor work.
- Added clause-level ownership to hybrid plans, keeping computer and private-screen operations with central Rook while limiting pawn assignments to the remaining specialist clauses.
- Added one ordered direct-capability guide for Reflex, weather, Spotify, private screen capture, Mac controls, and fresh Librarian answers, with an inspectable adapter and fallback description for every route.
- Added a bounded semantic weather fallback for natural forecast language such as rain, umbrella, and casual temperature questions.
- Added explicit private ScreenCaptureKit capture for the active display, frontmost window, or named visible app/window, with exact-request Codex image attachment and native Canvas display.
- Added Screen Recording permission setup, bounded capture routing, private-media storage, and parser coverage for natural screenshot and visual-inspection commands.
- Added generated-image handoff from deep Rook to Canvas using a private native media store, opaque asset IDs, inline full-image viewing, and Codex saved-path/base64 recovery.
- Confirmed and hardened direct public HTTPS image rendering with private-host, credential, auth-token, and tracking-parameter rejection.
- Added fully clickable Library inspection for task and context pawns, graph-path segments, project/category/topic nodes, connected folders, imported source records, and attached archive notes.
- Added durable per-pawn result and evidence fields with backward-compatible older archives and an explicit no-raw-reasoning boundary.
- Added bounded source-context provenance to graph nodes and their Obsidian-compatible Markdown notes.
- Added an Obsidian-compatible Librarian graph with durable project, category, and topic nodes, wiki-linked Markdown notes, automatic archive backfill, and high-level project seeding from the local Codex memory registry.
- Added deterministic implicit-project resolution for a sole matching project or a clearly dominant matching project, with visible resolved labels and ambiguity protection.
- Added Phase 2Q direct OAuth foundation for shared Google (Gmail + Calendar) and Spotify connections using Authorization Code + PKCE, a temporary loopback callback, Keychain-only token storage, refresh-token support, and live Allies statuses.
- Added in-app client-ID setup, browser authorization, account labeling, connect/disconnect controls, and provider-specific setup guidance.
- Added OAuth configuration, PKCE, scope-boundary, expiry, and persistence tests.
- Added Phase 2R direct Spotify commands for named playlist and catalog playback, playlist summaries, recent listening, top tracks and artists, now-playing state, device discovery, and playback transfer.
- Added a durable pending-conversation layer that keeps Rook's unanswered question, source request, bounded choices, domain, and expiry across app launches.
- Added pre-router continuation handling for short answers, explicit retries, cancellation, expiry, and clear topic switches, with typed Spotify playlist follow-ups staying on the zero-pawn native path.
- Routed play, pause, next, and previous through Spotify OAuth when connected, and prevented spoken Spotify corrections from falling into Computer Control.
- Made Spotify an authoritative local routing domain: natural playlist/top-track phrases resolve natively, ambiguous playback asks locally, and unsupported Spotify operations cannot fall into Computer Control.
- Added a Spotify Canvas panel with source attribution and uncropped provider artwork.
- Added the native Rook iPhone companion foundation with Today, Canvas, Library, Moves, foreground push-to-talk, and device-authenticated approval UI.
- Added a versioned phone/Mac protocol with directional message validation, authentication requirements, message bounds, and replay-window checks.
- Added an expiring one-time pairing store that persists only session-token hashes and supports paired-device revocation.
- Added address-free iPhone pairing with a Mac-generated QR code, Bonjour discovery, per-message authenticated encryption, Keychain session persistence, central-Rook command routing, sanitized snapshots, and exact move-decision recording.
- Expanded the iPhone companion into a four-surface command center with Home, live Activity, searchable Library, exact Moves, persistent ask controls, quick asks, and Mac/Ally connection settings.
- Added sanitized task-run and Ally projections to the versioned mobile snapshot while preserving central-Rook-only responses, Mac-held credentials, and exact approval boundaries.
- Added Phase 2S local-first mobile transport with an automatic outbound WSS relay fallback for cellular and unrelated Wi-Fi networks, while preserving the existing encrypted protocol and Mac authority.
- Added a no-storage Cloudflare Durable Object relay, bounded binary forwarding, role replacement, per-connection rate limits, deployment-key authentication, replay rejection, integration tests, and secret-safe deployment/configuration tooling.

### Changed

- Same-domain phrases such as `find and play me a study playlist` now remain one native Spotify action instead of being split into a Scout research clause plus playback. True cross-domain requests still produce ordered hybrid plans.
- Spotify playlist follow-ups now resolve spoken ordinals such as `option one`, `choice number two`, and `playlist 3` against the preserved visible choices instead of searching Spotify for those words literally.
- Missing literal focus-style playlist names now fall back to personal-library inference; close ties become a usable native playlist question instead of an error, and recommendation requests no longer repeat the full playlist count as their answer.
- Compound requests are no longer forced into a single native, clarification, or pawn route. Supported native compounds remain instant, while mixed direct-plus-specialist commands enter one deliberate session that preserves the requested order.
- Mobile now replaces a stale relay channel whenever the same iPhone is paired again, permits cellular and constrained URLSession paths explicitly, serializes foreground reconnect attempts, and reconnects automatically when Wi-Fi drops or the app returns to the foreground. Relay socket replacement now excludes closing WebSockets and contains synchronous close/send races so a stale connection cannot return HTTP 500 to its replacement.
- Weather and Spotify now get their exact and semantic native attempts before general routing regardless of OAuth connection state; a known-domain adapter decline explicitly escalates the intact request to central Rook and its pawn crew.
- Changed screen-aware deep sessions and approval follow-ups from `never` to `on-request` and routed them through an approval-capable app-server host. Computer Use app-access handshakes are accepted and persisted silently, while ordinary deep work keeps its existing path and shell, file, other-connector, and consequential-action guardrails remain intact.
- Tightened instant-weather routing to a bounded forecast command grammar so longer Canvas or image questions that merely mention weather reach central Rook.
- Routed product-feature requests such as social-app following or messaging work to central Rook's deliberate code path and kept closely related concepts such as group chats under broad topic nodes.
- Launch graph-resolved deliberate work inside the verified project checkout while preserving Rook's private state directory for guarded Library and queue writes.
- Gmail and Calendar remain available via Codex while direct Google authorization is configured; Spotify retains its zero-model local playback bridge when OAuth is absent.
- Spotify OAuth now uses the dashboard-compatible fixed `127.0.0.1:8888` loopback callback and routes supported account commands directly without Codex or pawns.
- Standardized repository formatting, validation, contribution, security, and architecture documentation.
- Added the canonical, version-controlled Rook skill and install-time synchronization.
- Added deterministic conversational retry resolution, a bounded recent-thread context feed, and visible resolved-task labels.
- Resolve answers to Rook's own questions before prompt polishing, normal parsers, Computer Control, models, or pawn deployment.
- Moved natural basic Spotify requests such as `play my Spotify` onto the native zero-pawn control path.
- Archive deliberate responses that report an error as blocked instead of completed.

## [2.12] - 2026-08-11

### Added

- Phase 2O Rook Reflex for local calculations, conversions, timers, reminders, device status, volume controls, and fresh-checkpoint `what's next` answers.
- Phase 2N native weather with guarded caching and explicit provenance.
- Phase 2M instant and screen-aware macOS control paths.
- Phase 2L structured Rook Canvas rendering.
- Phase 2J Librarian archives, task manifests, preferences, and read-only Gmail/Calendar checkpoints.

### Safety

- Preserved central-Rook-only action authority, approval-gated consequential changes, and read-only pawn and Librarian workers.
