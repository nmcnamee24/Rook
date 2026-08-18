# Rook

Rook is a private macOS voice companion and command center, with a native iPhone companion now in development. It uses a Rook-owned LiveKit WakeWord ONNX model for local wake detection, macOS 26 SpeechAnalyzer and SpeechTranscriber for on-device command recognition, the ChatGPT-authenticated Codex runtime already installed with ChatGPT, bounded Codex pawn delegation, an approval queue, and local Kokoro neural text-to-speech. It does not require a wake-word account, a Wispr API key, or an OpenAI Platform API key.

| Release | Phase | Platform | Language | Status |
|---|---|---|---|---|
| 2.27 (build 30) | 2W Rook-owned local wake | macOS 26 | Swift 6.2 | Active, private |
| 0.2 | Mobile companion | iOS 26 | Swift 6 | Local-first, internet-relayed connection implemented |

## Repository guide

- [Architecture](docs/ARCHITECTURE.md) explains routing, components, and trust boundaries.
- [Development log](docs/DEVELOPMENT_LOG.md) records product-critical gaps, benchmarks, and current engineering priorities.
- [Contributing](CONTRIBUTING.md) defines the development and verification workflow.
- [Security policy](SECURITY.md) documents private reporting and protected boundaries.
- [Changelog](CHANGELOG.md) records user-visible phases and releases.
- [Mobile companion](docs/MOBILE.md) records the iPhone architecture, implemented boundary, and next milestone.
- [Mobile relay](docs/RELAY.md) explains deployment, secret handling, and remote-connection verification.
- [Connections](docs/CONNECTIONS.md) explains direct Google and Spotify OAuth setup, requested scopes, and the current migration boundary.
- [`skill/rook/`](skill/rook/) is the canonical Rook skill synchronized during installation.

## Default flow

1. Say **“Rook”** followed by a command in the same natural utterance.
2. When enrolled, the green ready meter streams 16 kHz audio to the local personalized wake model. After Rook hears it, the meter turns red and tracks both adaptive live voice activity and the 1.4-second pause before submission.
3. Rook transcribes locally with Apple's newer macOS 26 SpeechTranscriber model.
4. A Wispr-style prompt-polish pass removes fillers, repeated starts, and common dictation artifacts locally with no model wait. An experimental Codex rewrite remains available in configuration, but is disabled by default because currently available Codex models do not reliably finish inside the subsecond budget.
5. If Rook has asked for a missing detail, it keeps that open question as private live state. The next short answer is resolved against the unfinished request before prompt polishing, parsers, models, Computer Control, or pawns; a clear topic switch cancels that open loop and routes normally.
6. A deterministic preflight resolves open follow-ups, retries, unique recent referents, and only exact typed fast paths. Rook Reflex, basic weather, exact Spotify commands, explicit private screen capture, narrow Mac controls, and a fresh Librarian checkpoint may finish immediately. The preflight does not guess from domain keywords or split a semantic request into owners.
7. Every unclaimed, semantic, compound, uncertain, or declined request goes intact to a prewarmed, read-only **Central Rook delegator**. It understands the complete intended outcome and returns one structured decision: answer now, ask one clarification, or begin deliberate work. This pass has no tools or external-action authority.
8. When work is needed, Central Rook starts a separate high-reasoning session and remains responsible for native capabilities, tools, safety gates, dependencies, and the final synthesis.
9. Central Rook may give a deliberate prompt an independent crew of up to ten silent pawn instances. Scout, Forge, Scribe, Steward, and Auditor are optional specialists rather than keyword-selected defaults. The older native hybrid planner remains only for safely resuming an already-open Spotify workflow with verified dependency receipts.
10. Central sessions for different prompts may deliberate at the same time. Only Central Rook speaks or presents each crew's final synthesis.
11. Background Rook may create or update safe personal Calendar events and save Gmail drafts. Consequential actions remain queued.
12. The Librarian is a separate always-active context brain. After every response it compresses and labels the turn; requests that used specialist pawns also receive their own task folder with the outcome, pawn list, and exact block or interruption reason.
13. While Rook is idle, the Librarian dispatches its own strictly read-only Calendar, Gmail, retrieval, and audit pawns every 30 minutes. Fresh snapshots can be answered locally with an explicit **as-of** time.
14. Exact current, tomorrow, and one-to-seven-day weather commands use a direct native Open-Meteo path. Rook warms a ten-minute cache from an approximate Mac location, so a warm forecast renders immediately and a named-city cache miss normally needs only one or two short API calls. Natural, contextual, or decision-oriented weather language goes through Central Rook instead of being guessed from weather words.
15. Sourced answers may include native Rook Canvas views for weather, Calendar, Spotify, online reference images, privately generated images, code fixes, diagrams, computer controls, or general structured results. The visual supplements the concise answer instead of replacing it.
16. Exact low-risk Mac commands use the instant local controller. `Open Safari and search for…`, `open Notes`, basic Spotify controls, and exact named Spotify requests do not wait for Central Rook. Broader Spotify language stays intact for Central rather than receiving a hasty semantic guess from the local gate.
17. Rook Reflex handles bounded calculations, common conversions, local timers and reminders, battery/storage/volume checks, and exact volume controls without a model. “What's next?” reads one event from the Librarian's fresh checkpoint with a countdown and as-of time. If an exact adapter declines or no exact parser claims the request, Central Rook receives the whole command and decides what happens next.

The same Apple transcription session stays open before and after the acoustic wake event, so **“Rook, open…”** does not lose the first command words or require a pause. If the owned model is missing, neither validated nor explicitly trial-enabled, or unloadable, Rook labels and uses its earlier Apple wake matcher as a compatibility fallback.

## Command center

Rook opens a native editorial workspace with five views:

- **Today** leads with the most useful native Rook Canvas view when a result is better seen than described, then renders the supporting Markdown. Weather becomes a compact forecast, Calendar becomes a timeline, public online images appear with attribution, generated images stay private in Rook's media store, code fixes can switch between original and proposed snippets, and workflows can become diagrams.
- **Pawns** is the live operations floor: it groups task-pawn instances by the prompt that deployed them, shows repeated roles as distinct workers such as **Steward 1** and **Steward 2**, and preserves visible stop reasons. It contains no disable controls.
- **Library** is the Librarian's inspectable workspace: every project, category, topic, graph-path segment, archive note, task pawn, and context pawn is clickable. Node dossiers expose all stored relationships, source records, aliases, matching terms, workspaces, and attached conversations. Pawn dossiers expose the assignment, attributable result, evidence, status, and central synthesis without exposing hidden reasoning.
- **Allies** is the connection board: Gmail and Google Calendar retain their Codex-managed path while offering one shared direct Google sign-in, Spotify separates working local playback from direct account OAuth, and the remaining integrations stay visibly ranked until they are actually connected.
- **Moves** shows consequential actions using short human labels such as **Move hike time** instead of exposing internal queue IDs. Reviewing a move never executes it.

The bottom voice dock says **Just say “Rook”** when ready. Its circular meter and waveform expose wake detection, active capture, silence-to-send timing, processing, and speaking; the typed-command fallback remains available. Rook's menu-bar waveform icon can reopen the command center after its window is closed.

## Install

```bash
./scripts/install-kokoro.sh
./scripts/build-app.sh
./scripts/install.sh
```

The pinned LiveKit WakeWord runtime is built and installed with Rook. It is Apache-2.0 software, runs locally through ONNX Runtime, and needs no account, access key, cloud call, or per-device fee. Rook activates only a model whose exact SHA-256 digest is authorized by either a passing corpus report or an explicit owner trial manifest.

To produce the owned model:

```bash
brew install ffmpeg espeak-ng
make enroll-wake                 # private training recordings
make train-wake                  # production-scale synthetic + personal training
make trial-wake                  # explicitly activate the current unvalidated candidate
make record-wake-evaluation      # held-out samples; never used for training
make record-wake-negative        # repeat until the negative corpus reaches 24 hours
make promote-wake                # refuses promotion unless every gate passes
make install
```

Production training uses the pinned source revision recorded in `Package.swift` and [the production configuration](WakeModel/rook-production.yaml). It downloads roughly 18 GB of reusable training assets and can take hours; `./scripts/train-livekit-wake.sh bootstrap` provides a smaller end-to-end engineering check but can never bypass validation. `make trial-wake` is an explicit owner override that installs the current candidate with a SHA-256-bound, visibly unvalidated trial manifest; it does not forge or bypass a passing evaluation, and Apple fallback remains available if the local runtime fails. Training recordings, generated data, candidates, active models, and corpus audio stay out of Git under `.artifacts.noindex` or `~/.codex/rook/wake`. See the [LiveKit WakeWord project](https://github.com/livekit/livekit-wakeword) and its [Apache-2.0 license](https://github.com/livekit/livekit-wakeword/blob/main/LICENSE).

To validate a model instead of trusting a few demos, place uncompressed 16 kHz mono 16-bit PCM WAV files under `~/.codex/rook/wake/corpus/positive/<profile>/` and negative audio under `~/.codex/rook/wake/corpus/negative/`, then run `make evaluate-wake`. The release gate requires 20 or more positives and at least 95% recall in each of `quiet`, `whisper`, `continuous`, `office-noise`, `coffee-shop-noise`, and `far-field`, plus 24 hours of negative audio with no more than one false activation per 24 hours. `make promote-wake` runs that gate against the candidate, binds the passing report to the exact model digest, preserves any previous active model, and only then installs it. `./scripts/doctor.sh` reports the runtime, model, validation, and fallback state.

Installation also synchronizes the version-controlled skill from `skill/rook/` to `~/.codex/skills/rook`. Run `make check-skill` at any time to verify that the installed skill matches the repository.

Rook 2.27 requires macOS 26. On first launch, approve **Microphone**, **Speech Recognition**, and approximate **Location** when macOS asks. Location lets Rook prepare instant local weather before you ask; you can also say a city explicitly without enabling Location. The first local timer or reminder may also ask for **Notifications** so the alert can appear if Rook is in the background. Screen capture is opt-in and requested only when you explicitly ask Rook to look at a display or window. Rook appears as a `♜` in the menu bar and does not show a Dock icon.

Direct Google and Spotify OAuth begins in **Allies**. **Connect Spotify** opens Spotify in your normal browser with Rook's public app identity; no Client ID is shown in the ordinary flow. Rook protects authorization with PKCE and a loopback callback and stores refresh/access tokens only in macOS Keychain. Developer builds may inject a public Spotify Client ID without adding a client secret. See [Connections](docs/CONNECTIONS.md) for the exact boundary. Spotify uses its stored token directly for account data, search, devices, and playback. Gmail and Calendar continue using the proven Codex connectors until their guarded native clients are enabled.

Computer control has two layers:

- **Instant controls:** open or switch to an installed app, open an HTTP(S) page, search in Safari/Chrome/Firefox/Arc, and play, pause, skip, or go back in Spotify. With direct Spotify connected, exact named-playlist or catalog playback, semantic study/work/focus playlist selection, playlist lists, recent listening, top items, now-playing state, devices, and playback transfer also stay local and deploy no pawns.
- **Private screen capture:** explicit requests can capture the active display, frontmost window, or a named app/window with ScreenCaptureKit. Rook stores that image in its private local media folder, attaches it only to the authenticated central Codex request that needs to understand it, and shows the private capture in Canvas. The Rook window is excluded from full-display captures, capture content is not copied into speech or Library records, and macOS requires **Screen & System Audio Recording** permission the first time.
- **Operator controls:** multi-step visible work such as navigating an app without a supported direct command, inspecting a page, clicking controls, or arranging windows. Clicking and typing may require **Accessibility** access. Use **Rook menu → Screen & Computer Setup…** for both permissions. Spotify may separately show a one-time Automation prompt for the basic Mac bridge.

Examples: `Rook, take a screenshot of my screen`, `Rook, look at the Safari window and tell me what is wrong`, `Rook, capture the frontmost window`, `Rook, open Notes`, or `Rook, play my Focus playlist on Spotify`.

Short follow-ups keep their conversational referent. `Try that again` repeats the latest eligible request from the prior two hours; `try Spotify again` can recover the most recent Spotify request even after the topic changes. Rook shows the resolved task label on screen, and stale or genuinely ambiguous references still trigger one clarification.

When Rook itself asks a question, it stores one private open loop containing the source request, exact question, bounded choices, and a 30-minute expiry. Replies such as `the second one`, `tomorrow at 3`, `yes`, or `my top tracks playlist` fill that missing detail before normal routing. `Never mind` drops the loop, a clear new request switches topics, and `try that again` reruns the original request instead of being mistaken for an answer. The state survives an app restart in `pending_conversation.json` and is removed as soon as it is resolved, cancelled, superseded, or expires.

Project references are durable too. Named work becomes a project node with category and topic branches—for example, `Jocks Links → Social Media → Messaging`. Later requests such as `add a following system to my social media app` resolve to the only matching project, or to a matching project whose established activity clearly dominates alternatives. The resolved project is shown on screen; genuinely tied projects still require one clarification.

For deliberate coding work, Central Rook resolves and verifies one live checkout under the user's home folder, then hands the intact request to one saved full Codex task. That task inherits the user's normal Codex configuration instead of Rook's background model or response schema. Rook remains the front door and result presenter; Codex owns the coding history, implementation, and verification. If no unique checkout is known, Rook asks instead of guessing. Private task receipts remain under Rook state while live checkout contents override stale graph context.

On first graph-aware launch, the Librarian seeds project identity and activity from the high-level local Codex memory registry when available. It reads task-group checkout paths and bounded source-context records, skips transient Codex run folders, and does not import raw session transcripts into the graph. The source records remain expandable from each matching node so graph provenance is auditable.

Reflex examples: `Rook, what is 15 percent of 240?`, `Rook, convert 5 miles to kilometers`, `Rook, set a timer for 20 minutes called pasta`, `Rook, remind me tomorrow at 8 AM to pack my charger`, `Rook, what's my battery?`, `Rook, set volume to 50 percent`, or `Rook, what's next?`. Local Rook reminders are private app alerts, not Apple Reminders items.

The default voice is Kokoro's British male `bm_daniel`, generated entirely on-device by a preloaded worker. If the local neural runtime is unavailable, Rook falls back to macOS's British `Daniel` voice so spoken responses still work.

## iPhone companion

`RookMobile.xcodeproj` contains the native iOS companion. Its Home surface combines push-to-talk, typed input, live work, the latest answer, Canvas, and quick asks. Activity follows task crews and attributable pawn status; Library provides searchable outcomes; Moves handles exact device-authenticated decisions. Settings shows the private Mac link and sanitized Ally availability. The Mac remains the sole Codex, connector, file, and computer-control host, and all pairing state stays Keychain-backed.

Build the iOS target without signing:

```bash
make mobile
```

To connect, run the iOS target on your iPhone once, keep the phone and Mac on the same Wi-Fi network for the initial pairing, then choose **Rook menu → Pair iPhone…** on the Mac and scan the QR from the phone. After the private relay is deployed, the phone tries Bonjour nearby and automatically falls back to the built-in encrypted relay over cellular or another Wi-Fi network. There is no IP address, port forwarding, VPN, or separate networking app to configure. The QR expires after five minutes, every bridge message is authenticated and end-to-end encrypted, and reconnect secrets stay in Keychain.

One Cloudflare authorization is required to create the private relay endpoint. Run `npx wrangler login` in `Relay/`, then `./scripts/deploy-mobile-relay.sh`; see [Mobile relay](docs/RELAY.md). Rook Mobile currently connects while it is in the foreground.

To start Rook automatically when you sign in:

```bash
./scripts/install.sh --login
```

## Diagnostics and safe text test

```bash
./scripts/doctor.sh
~/Applications/Rook.app/Contents/MacOS/Rook --speak-test "Good afternoon. Rook is ready."
~/Applications/Rook.app/Contents/MacOS/Rook --ask-fast "Say hello without using pawns."
~/Applications/Rook.app/Contents/MacOS/Rook --polish-local "Um, I want to I want to, like, clean up this prompt"
~/Applications/Rook.app/Contents/MacOS/Rook --weather-fast "Weather in Oakland, New Jersey over the next 3 days"
~/Applications/Rook.app/Contents/MacOS/Rook --reflex-fast "What is 15 percent of 240?"
~/Applications/Rook.app/Contents/MacOS/Rook --ask-live "Why is the sky blue?"
~/Applications/Rook.app/Contents/MacOS/Rook --ask "Give me a one-sentence Rook status check."
~/Applications/Rook.app/Contents/MacOS/Rook --checkpoint
~/Applications/Rook.app/Contents/MacOS/Rook --library-context "Why was the link task interrupted?"
~/Applications/Rook.app/Contents/MacOS/Rook --benchmark-routing
~/Applications/Rook.app/Contents/MacOS/Rook --fast-path-readiness
~/Applications/Rook.app/Contents/MacOS/Rook --run-fast-path-scenario-once app_launch
~/Applications/Rook.app/Contents/MacOS/Rook --record-manual-baseline spotify_resume 3000
~/Applications/Rook.app/Contents/MacOS/Rook --record-attention-advantage spotify_resume "Hands-free playback while another app stays focused."
~/Applications/Rook.app/Contents/MacOS/Rook --trace-summary
~/Applications/Rook.app/Contents/MacOS/Rook --coding-task /path/to/project "Fix the failing tests and verify the result."
```

`--speak-test` exercises the same neural speech path as the live app without starting the microphone. `--ask-fast` tests only the exact local gate, and `--polish-local` shows the exact zero-network cleanup applied after dictation. `--weather-fast` benchmarks the direct weather parser, fetch, formatter, and Canvas without a model, and `--reflex-fast` benchmarks an exact Reflex command. `--ask-live` retains the legacy streamed-answer diagnostic, and `--ask` exercises the legacy blocking diagnostic path; neither is the live app's Central delegation route. `--checkpoint` performs and stores one guarded read-only Calendar/Gmail refresh; `--library-context` prints the same compact retrieval snapshot Rook receives for a query. `--benchmark-routing` runs the deterministic exact-gate suite without executing external actions. `--run-fast-path-scenario-once` performs one explicitly selected real native action and records its private trace; it never loops. `--fast-path-readiness` applies the 250 ms, 99%, verified-outcome, no-fallback, streaming-prewarm, and manual-advantage gates without treating missing data as a pass. `--record-manual-baseline` stores one measured manual time, while `--record-attention-advantage` stores a concise explicit reason a hands-free path requires less attention. `--trace-summary` reports retry-aware first-attempt success and latency, and `--coding-task` exercises the same saved full-Codex handoff used by Central Rook for an explicitly supplied checkout and coding request.

For deterministic UI development without starting speech recognition or changing private state:

```bash
./.artifacts.noindex/Rook.app/Contents/MacOS/Rook --ui-preview
```

The selected visual reference, native captures, focused comparisons, and passing design QA report live under `Design/` and `design-qa.md`.

## Private state

Rook stores configuration, its Codex thread identifier, the latest full text and structured Canvas response, and diagnostic logs under:

`~/.codex/rook/core`

The folder is mode `700`; its files are mode `600`. Rook never reads or copies the underlying ChatGPT credential. Codex handles authentication through its own local credential cache.

Per-request traces live under `~/.codex/rook/core/traces`. They use monotonic elapsed time and record request source, speech milestones, interpreted intent, selected route, adapter start, outcome, verification, failure category, and recovery recommendation. Traces remain private local diagnostics; they never contain OAuth tokens or raw provider payloads.

Full Codex handoff receipts live under `~/.codex/rook/core/coding_tasks`. Each mode-600 record maps one Rook request to its saved Codex thread, verified checkout, status, bounded final summary, and exact interruption or failure reason. Activity shows generic progress only; command output and private file contents are not copied into progress labels or speech.

The Librarian's durable state lives under `~/.codex/rook/library`:

- `index.json` — searchable labels, timestamps, status, compact outcomes, and saved stop reasons.
- `graph.json` — authoritative project, category, topic, workspace, relationship, source-context, and attached-turn nodes with activity evidence.
- `nodes/` — private Obsidian-compatible Markdown notes whose folders and wiki links mirror the graph.
- `conversations/YYYY/MM/DD/` — one private archive folder after every chat.
- `tasks/YYYY/MM/DD/` — one task folder whenever prompt-specific task pawns were used, including each pawn's attributable result and evidence when captured.
- `checkpoints/` — the latest and historical read-only Calendar/Gmail snapshots.
- `preferences/profile.json` — explicit preferences plus evidence counts for inferred habits.
- `preparations/` — private local meeting briefs after that habit becomes active.

Generated Canvas images and explicitly requested screen captures live under `~/.codex/rook/media` with private directory and file permissions. Model output receives only an opaque Rook asset ID, never the local path. A screen capture is attached as image input only to the authenticated central Codex request that triggered it. The Mac Canvas can display either image inline and open the full-resolution local copy on request.

Explicit preferences such as a stated home location activate immediately. Inferred habits, such as repeatedly asking for pre-meeting notes, activate only after two independent examples. Learned habits may prepare local context; they do not silently send mail or perform new external actions.

`status.json` records only the current local state—such as waiting for setup, listening, thinking, or speaking—and contains no transcript.

`weather_cache.json` contains up to twelve recent forecasts and approximate coordinates, is stored with private file permissions, refreshes every eight minutes while Rook runs, and is considered live for ten minutes. Rook sends coordinates only to Open-Meteo for forecast retrieval. Basic forecast calls have a two-second request budget and use a recent cached forecast for up to two hours if the service briefly fails.

`reflex_alerts.json` contains local timer/reminder labels, due times, and state. It uses the same private file permissions. Rook schedules a macOS notification and an in-app timer; reminder text is shown on screen, while spoken due alerts stay generic so private content is not read aloud unexpectedly.

The prewarmed structured Central delegator uses `gpt-5.6-luna` with low reasoning and no tools. Prompt cleanup itself is local and immediate. The optional no-tools Codex rewrite is controlled by `prompt_polish_enabled`, defaults to `false`, and retains a `prompt_polish_wait_milliseconds` ceiling of `900`; exact native commands bypass it regardless. Deep Central deliberation and pawns use `gpt-5.6-terra` with high reasoning. Exact fast-path answers, Library indexing, and fresh checkpoint answers are local and use no model. Legacy configs receive these defaults automatically, and prompt crews use five roles with up to ten instances while the Librarian remains independent. Edit `config.json` only while Rook is quit.

Rook Canvas does not require an API key for weather. Basic forecasts use Open-Meteo directly; weather-dependent decisions, alerts, radar, travel safety, and contextual questions still use central Rook's research path. Calendar views use the connected primary Calendar or the Librarian's timestamped checkpoint. Online images must be direct public HTTPS resources, and Canvas rejects local, private-network, credential-bearing, authenticated, tracking, data, file, or insecure URLs. Images generated in the current deep Rook turn are copied into the private media store and attached to Canvas by trusted native code.

## Safety boundary

The background voice process can read, research, plan, create or update Gmail drafts, create or update exact attendee-free, non-recurring events on the primary Calendar, capture a display or visible window when explicitly requested, and perform explicitly requested low-risk computer controls. Safe Calendar updates preserve every field the user did not explicitly change and are read back before success is reported. Rook silently accepts Computer Use app-access handshakes so ordinary UI tasks do not pause for per-app permission prompts; this does not approve shell, file, Gmail/Calendar, or other connector escalations. Computer control does not turn `handle it`, `anything`, or silence into blanket permission: sending, publishing, purchasing, booking, applying, deleting, installing, sharing private files, changing access/security settings, entering credentials, or accepting legal terms stops at the exact approval or handoff boundary. Gmail sends remain approval-gated even when performed through an app UI. The recurring checkpoint uses a stricter connector profile: every Calendar and Gmail write tool is disabled and the Librarian never captures or controls apps.

## Remove

```bash
./scripts/uninstall.sh
```

Uninstalling moves the app and login item to Trash and preserves private Rook state.
