# Rook Core — Phase 2O

Rook Core is a private macOS voice companion and command center. It uses macOS 26 SpeechAnalyzer and SpeechTranscriber for high-quality on-device recognition, the ChatGPT-authenticated Codex runtime already installed with ChatGPT, bounded Codex pawn delegation, the existing Rook approval queue, and local Kokoro neural text-to-speech. It does not require a Wispr API key or an OpenAI Platform API key.

## Default flow

1. Say **“Rook”** followed by a command in the same natural utterance.
2. The green ready meter listens for the wake word. After Rook hears it, the meter turns red and tracks both live voice energy and the 1.4-second pause before submission.
3. Rook transcribes locally with Apple's newer macOS 26 SpeechTranscriber model.
4. A deterministic local router acknowledges the request immediately without waiting for a model.
5. Stable ordinary questions run on a prewarmed, read-only Codex thread and appear token-by-token as the answer arrives. That thread has no tools or external-action authority.
6. Complex, live, uncertain, file-backed, or multi-step work bypasses the ordinary model and starts a separate high-reasoning background session immediately.
7. Every deliberate prompt receives an independent crew of up to ten silent pawn instances. Scout, Forge, Scribe, Steward, and Auditor are available, and a role may appear more than once for independent subtasks.
8. Crews for different prompts may deliberate at the same time. Only central Rook speaks or presents each crew's final synthesis.
9. Background Rook may create or update safe personal Calendar events and save Gmail drafts. Consequential actions remain queued.
10. The Librarian is a separate always-active context brain. After every response it compresses and labels the turn; requests that used specialist pawns also receive their own task folder with the outcome, pawn list, and exact block or interruption reason.
11. While Rook is idle, the Librarian dispatches its own strictly read-only Calendar, Gmail, retrieval, and audit pawns every 30 minutes. Fresh snapshots can be answered locally with an explicit **as-of** time.
12. Basic current, tomorrow, and one-to-seven-day weather requests use a direct native Open-Meteo path. Rook warms a ten-minute cache from an approximate Mac location, so a warm forecast renders immediately and a named-city cache miss normally needs only one or two short API calls—never a model or pawn crew.
13. Sourced answers may include native Rook Canvas views for weather, Calendar, images, code fixes, diagrams, computer controls, or general structured results. The visual supplements the concise answer instead of replacing it.
14. Exact low-risk Mac commands use the instant local controller. `Open Safari and search for…`, `open Notes`, `pause Spotify`, and track controls do not wait for a model. Screen-aware requests such as selecting a named Spotify playlist use central Rook's Operator path; pawns may plan and verify, but never control the UI.
15. Rook Reflex handles bounded calculations, common conversions, local timers and reminders, battery/storage/volume checks, and exact volume controls without a model. “What's next?” reads one event from the Librarian's fresh checkpoint with a countdown and as-of time. Vague requests automatically continue through central Rook.

If Apple Speech finalizes **“Rook”** as its own utterance, Rook silently continues listening for the command for eight seconds. It no longer speaks “Ready” over the start of your request.

## Command center

Rook opens a native editorial workspace with four views:

- **Today** leads with the most useful native Rook Canvas view when a result is better seen than described, then renders the supporting Markdown. Weather becomes a compact forecast, Calendar becomes a timeline, reference images appear with attribution, code fixes can switch between original and proposed snippets, and workflows can become diagrams.
- **Pawns** is the live operations floor: it groups task-pawn instances by the prompt that deployed them, shows repeated roles as distinct workers such as **Steward 1** and **Steward 2**, and preserves visible stop reasons. It contains no disable controls.
- **Library** is the Librarian's workspace: searchable and filterable archive notes, exact stop reasons, task crews, learned preferences, current context freshness, and the Librarian's own read-only context pawns.
- **Moves** shows consequential actions using short human labels such as **Move hike time** instead of exposing internal queue IDs. Reviewing a move never executes it.

The bottom voice dock says **Just say “Rook”** when ready. Its circular meter and waveform expose wake detection, active capture, silence-to-send timing, processing, and speaking; the typed-command fallback remains available. Rook's menu-bar waveform icon can reopen the command center after its window is closed.

## Install

```bash
./scripts/install-kokoro.sh
./scripts/build-app.sh
./scripts/install.sh
```

Rook 2.12 requires macOS 26. On first launch, approve **Microphone**, **Speech Recognition**, and approximate **Location** when macOS asks. Location lets Rook prepare local weather before you ask; you can also say a city explicitly without enabling Location. The first local timer or reminder may also ask for **Notifications** so the alert can appear if Rook is in the background. Rook appears as a `♜` in the menu bar and does not show a Dock icon.

Computer control has two layers:

- **Instant controls:** open or switch to an installed app, open an HTTP(S) page, search in Safari/Chrome/Firefox/Arc, and play, pause, skip, or go back in Spotify.
- **Operator controls:** multi-step visible work such as finding a named playlist, navigating an app, inspecting a page, clicking controls, or arranging windows. On the first screen-aware request, macOS may require **System Settings → Privacy & Security → Accessibility** access. Use **Rook menu → Computer Control Setup…** to open that page. Spotify may separately show a one-time Automation prompt.

Examples: `Rook, open Safari and search for American University events`, `Rook, open Notes`, `Rook, pause Spotify`, or `Rook, play my Focus playlist on Spotify`.

Reflex examples: `Rook, what is 15 percent of 240?`, `Rook, convert 5 miles to kilometers`, `Rook, set a timer for 20 minutes called pasta`, `Rook, remind me tomorrow at 8 AM to pack my charger`, `Rook, what's my battery?`, `Rook, set volume to 50 percent`, or `Rook, what's next?`. Local Rook reminders are private app alerts, not Apple Reminders items.

The default voice is Kokoro's British male `bm_daniel`, generated entirely on-device by a preloaded worker. If the local neural runtime is unavailable, Rook falls back to macOS's British `Daniel` voice so spoken responses still work.

To start Rook automatically when you sign in:

```bash
./scripts/install.sh --login
```

## Diagnostics and safe text test

```bash
./scripts/doctor.sh
/Users/noahmcnamee/Applications/Rook.app/Contents/MacOS/Rook --speak-test "Good afternoon. Rook is ready."
/Users/noahmcnamee/Applications/Rook.app/Contents/MacOS/Rook --ask-fast "Say hello without using pawns."
/Users/noahmcnamee/Applications/Rook.app/Contents/MacOS/Rook --weather-fast "Weather in Oakland, New Jersey over the next 3 days"
/Users/noahmcnamee/Applications/Rook.app/Contents/MacOS/Rook --reflex-fast "What is 15 percent of 240?"
/Users/noahmcnamee/Applications/Rook.app/Contents/MacOS/Rook --ask-live "Why is the sky blue?"
/Users/noahmcnamee/Applications/Rook.app/Contents/MacOS/Rook --ask "Give me a one-sentence Rook status check."
/Users/noahmcnamee/Applications/Rook.app/Contents/MacOS/Rook --checkpoint
/Users/noahmcnamee/Applications/Rook.app/Contents/MacOS/Rook --library-context "Why was the link task interrupted?"
```

`--speak-test` exercises the same neural speech path as the live app without starting the microphone. `--ask-fast` tests only the instant local router, `--weather-fast` benchmarks the direct weather parser, fetch, formatter, and Canvas without a model, and `--reflex-fast` benchmarks an exact Reflex command. `--ask-live` tests the streamed ordinary-answer thread, and `--ask` exercises the legacy blocking diagnostic path. `--checkpoint` performs and stores one guarded read-only Calendar/Gmail refresh; `--library-context` prints the same compact retrieval snapshot Rook receives for a query.

For deterministic UI development without starting speech recognition or changing private state:

```bash
./.artifacts.noindex/Rook.app/Contents/MacOS/Rook --ui-preview
```

The selected visual reference, native captures, focused comparisons, and passing design QA report live under `Design/` and `design-qa.md`.

## Private state

Rook stores configuration, its Codex thread identifier, the latest full text and structured Canvas response, and diagnostic logs under:

`/Users/noahmcnamee/.codex/rook/core`

The folder is mode `700`; its files are mode `600`. Rook never reads or copies the underlying ChatGPT credential. Codex handles authentication through its own local credential cache.

The Librarian's durable state lives under `/Users/noahmcnamee/.codex/rook/library`:

- `index.json` — searchable labels, timestamps, status, compact outcomes, and saved stop reasons.
- `conversations/YYYY/MM/DD/` — one private archive folder after every chat.
- `tasks/YYYY/MM/DD/` — one task folder whenever prompt-specific task pawns were used.
- `checkpoints/` — the latest and historical read-only Calendar/Gmail snapshots.
- `preferences/profile.json` — explicit preferences plus evidence counts for inferred habits.
- `preparations/` — private local meeting briefs after that habit becomes active.

Explicit preferences such as a stated home location activate immediately. Inferred habits, such as repeatedly asking for pre-meeting notes, activate only after two independent examples. Learned habits may prepare local context; they do not silently send mail or perform new external actions.

`status.json` records only the current local state—such as waiting for setup, listening, thinking, or speaking—and contains no transcript.

`weather_cache.json` contains up to twelve recent forecasts and approximate coordinates, is stored with private file permissions, refreshes every eight minutes while Rook runs, and is considered live for ten minutes. Rook sends coordinates only to Open-Meteo for forecast retrieval. Basic forecast calls have a two-second request budget and use a recent cached forecast for up to two hours if the service briefly fails.

`reflex_alerts.json` contains local timer/reminder labels, due times, and state. It uses the same private file permissions. Rook schedules a macOS notification and an in-app timer; reminder text is shown on screen, while spoken due alerts stay generic so private content is not read aloud unexpectedly.

The streamed ordinary-answer thread uses `gpt-5.6-luna` with low reasoning; background deliberation and pawns use `gpt-5.6-terra` with high reasoning. The immediate acknowledgment, routing decision, Library indexing, and fresh checkpoint answers are local and use no model. Legacy configs receive the Luna front-model default automatically, and prompt crews use five roles with up to ten instances while the Librarian remains independent. Edit `config.json` only while Rook is quit.

Rook Canvas does not require an API key for weather. Basic forecasts use Open-Meteo directly; weather-dependent decisions, alerts, radar, travel safety, and contextual questions still use central Rook's research path. Calendar views use the connected primary Calendar or the Librarian's timestamped checkpoint. Remote images must be direct public HTTPS resources, and Canvas rejects local, authenticated, or insecure image URLs.

## Safety boundary

The background voice process can read, research, plan, create or update Gmail drafts, create or update exact attendee-free, non-recurring events on the primary Calendar, and perform explicitly requested low-risk computer controls. Safe Calendar updates preserve every field the user did not explicitly change and are read back before success is reported. Computer control does not turn `handle it`, `anything`, or silence into blanket permission: sending, publishing, purchasing, booking, applying, deleting, installing, sharing private files, changing access/security settings, entering credentials, or accepting legal terms stops at the exact approval or handoff boundary. Gmail sends remain approval-gated even when performed through an app UI. The recurring checkpoint uses a stricter connector profile: every Calendar and Gmail write tool is disabled and the Librarian never controls apps.

## Remove

```bash
./scripts/uninstall.sh
```

Uninstalling moves the app and login item to Trash and preserves private Rook state.
