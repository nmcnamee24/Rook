# Rook Development Log

This log records product-critical observations, unresolved failures, and the order in which Rook should address them. It is deliberately separate from `CHANGELOG.md`: the changelog describes shipped behavior, while this file records where the product does not yet meet its intended bar.

## 2026-08-13 — Utility and reliability reset

### Current conclusion

Rook is a credible prototype, but it is not yet consistently more useful than performing common tasks manually or using Codex directly. The next milestone is not broader capability. It is making a small set of important workflows faster, more reliable, and at least as capable as their existing alternative.

The governing product test is:

> Does Rook complete the intended outcome with less time, effort, or attention than the user would spend doing it directly?

A feature does not pass merely because it works sometimes. For a short manual action, one recognition, routing, or execution failure can erase the value of many successful attempts. For a complex action, Rook should win through context, parallelism, and coordinated execution rather than by reproducing a slower version of an existing tool.

### P0: Fast-path utility and latency

#### Observations

- Commands such as playing Spotify or opening Safari can take longer through Rook than through direct interaction.
- The spoken request, end-of-speech delay, routing, and execution all count toward the user's perceived latency.
- A failed first attempt makes a three-second manual action substantially slower and damages trust in the entire interaction model.
- Exact native actions currently coexist with deeper model, hybrid, and Computer Use routes. Supported fast actions must never drift into a slower route merely because the wording varies naturally.

#### Required product behavior

- Instrument the complete path: wake detection, first transcript, final transcript, intent selection, adapter start, external outcome, and confirmation.
- Benchmark every fast action against a measured manual baseline on the same Mac.
- Route supported Spotify, browser, app-launch, and Reflex commands through deterministic native adapters without Codex, pawns, or Computer Use.
- Start executing from stable streaming intent when it is safe instead of waiting unnecessarily for a final transcript.
- Treat first-attempt success and correction rate as primary metrics alongside latency.
- Keep trivial commands only when they are genuinely hands-free, lower-effort, or at least competitive with the manual path. Rook's strongest value should come from useful multi-step outcomes, not from replacing one click with a sentence.

#### Initial acceptance bar

- A supported warm native action begins within 250 milliseconds of a stable finalized intent.
- Its end-to-end outcome is faster than the measured manual baseline or clearly requires less user attention.
- Supported benchmark phrases succeed on the first attempt at least 99% of the time under the tested conditions.
- No supported native action silently falls through to a model, pawn crew, or Computer Use path.

These targets are provisional until the first latency traces and manual baselines are captured.

### P0: Wake-word reliability

#### Observations

- Repeating “Rook” at a natural volume often does not wake the app.
- Recognition may require an unnatural pause and a loud, carefully enunciated wake word.
- This interaction is not viable in an office, coffee shop, or other environment where the user should be able to speak quietly or whisper.

#### Required product behavior

- Detect “Rook” when it leads directly into the command; do not require a pause after the name.
- Support quiet speech and whisper-level activation at normal working distance.
- Measure false rejects and false accepts separately in quiet, office-noise, coffee-shop-noise, and far-field conditions.
- Evaluate a dedicated streaming wake-word detector instead of relying on general Apple transcription to finalize the wake phrase.
- Preserve the existing privacy boundary: ambient audio stays local and only a command following a valid wake reaches Rook.

#### Initial acceptance bar

- Build a repeatable recorded test corpus covering normal speech, whispering, continuous “Rook, ...” commands, background conversation, and negative examples.
- Reach at least 95% wake recall in each supported acoustic profile while keeping false activation low enough for an all-day listener.
- Show wake acknowledgment quickly enough that the user never needs to wonder whether Rook heard them.

### P0: Transcription quality

#### Observations

- Current transcription is close to Apple's default SpeechTranscriber output with bounded cleanup afterward.
- Cleanup can remove fillers and repair formatting, but it cannot reliably recover names, URLs, commands, negations, or technical tokens that recognition never captured correctly.
- A stronger language-model cleanup stage alone would add latency and could confidently change the user's meaning.

#### Required product behavior

- Capture a private, consented evaluation corpus of real Rook commands and score both word error rate and intent-critical token accuracy.
- Compare Apple SpeechTranscriber against viable on-device and streaming alternatives using the same audio.
- Add phrase and entity biasing for app names, project names, contacts, playlist names, URLs, paths, and technical vocabulary where supported.
- Preserve raw recognized alternatives long enough for local intent resolution instead of collapsing immediately to one brittle transcript.
- Use cleanup only for presentation and conservative repair; never depend on it to reconstruct execution-critical meaning.

### P0: Intent, planning, and execution coherence

#### Observed failure

The request:

> “Open Spotify, play a playlist, and tell me about the song that's playing and research the artist.”

returned:

> “App control was blocked before play, lock play back, or song inspection.”

This contradicts the current architecture. With Spotify connected, playback and now-playing inspection belong to the direct Spotify client. Artist research belongs to deliberate research after the playback result is known. Computer Use should not own or block the supported Spotify steps.

#### Expected plan

1. Resolve the requested playlist or ask one bounded clarification if no unique playlist can be inferred.
2. Play it through the native Spotify API.
3. Read the actual current track and artist through the native Spotify API after playback succeeds.
4. Research that resolved artist through central Rook or a Scout.
5. Synthesize one answer while music continues playing.

#### Required engineering work

- Trace why inference or hybrid planning assigned supported Spotify work to app control.
- Represent hybrid dependencies explicitly: research of “the artist” must wait for the native now-playing result.
- Pass central native results into dependent specialist work without exposing credentials or delegating action authority.
- Distinguish a genuine provider/setup failure from an approval block and report the exact failed boundary.
- Add end-to-end planner-to-adapter tests for mixed native and research commands, not only unit tests for the individual parsers.

### P0: Coding must not be a weaker Codex

#### Observation

Rook's coding path is currently less capable than opening Codex directly. If it uses a weaker model, reduced context, restricted tools, an incorrect checkout, or extra orchestration that does not improve the result, Rook adds friction without adding value.

#### Product decision

Rook should not attempt to replace Codex's coding agent. It should be the voice, context, routing, and approval layer that hands coding work to a full-strength Codex task in the correct repository and then presents its progress and result coherently.

#### Acceptance bar

- A coding request routed through Rook receives the same repository context, model class, tool access, and verification expectations as the equivalent direct Codex request unless Rook displays a specific safety reason for a restriction.
- Rook's added latency is limited to intent/context preparation and does not serialize work that Codex can perform directly.
- Comparative evaluations use the same prompt and checkout through both paths and score correctness, completeness, elapsed time, and required user intervention.

## Benchmark set before further feature expansion

The following workflows should become the first repeatable product suite:

1. Wake quietly and play a uniquely named Spotify playlist.
2. Wake naturally and open Safari to one or more requested destinations.
3. Play a playlist, inspect the resulting track, and research the artist using the correct dependent hybrid plan.
4. Route a real coding task to full-strength Codex in the correct checkout and return the verified result.
5. Transcribe a representative set of ordinary, noisy, whispered, and technical commands without losing execution-critical meaning.

Record, for each run:

- first-attempt task success;
- end-to-end time to useful outcome;
- manual or direct-Codex baseline;
- route and adapter selected;
- number of corrections or clarifications;
- whether the final state was verified; and
- whether the user would choose Rook for the same task again.

## Repository decision

Centralize before doing more core capability work, but do not pause for a full public-repository makeover.

### Stabilization checkpoint now

1. Declare `/Users/noahmcnamee/Documents/Rook` the only editable source checkout.
2. Inventory the older `Documents/Codex/.../outputs/RookCore` tree and archive it after confirming every needed source and asset exists here. Do not delete it during the initial consolidation.
3. Keep installed/runtime destinations outside Git by design:
   - `~/Applications/Rook.app` is a generated installed product.
   - `~/.codex/skills/rook` is a synchronized installed copy; `skill/rook/` in this repository is canonical.
   - `~/.codex/rook` is private runtime state and must not be moved into the repository.
4. Create a coherent baseline from the current passing tree, split into reviewable commits where practical.
5. Add a private remote and push the baseline so the project is backed up and has one authoritative history. A private remote is not a public launch.
6. Verify that build, install, skill synchronization, tests, and release versioning all originate from this checkout.
7. Remove accidental files and resolve version drift before the checkpoint is tagged.

### Defer until the P0 workflows improve

- Public launch copy and screenshots.
- A polished commit history intended for outside contributors.
- Broad integration expansion.
- Additional Pawns, Canvas types, mobile surfaces, or convenience features.
- Public licensing and distribution decisions, except that a license must be chosen before making the repository public.

The intended order is therefore:

> minimum viable consolidation → measurement harness → P0 reliability and latency → external usability test → public packaging

The repository should become safe to build on now. It does not need to look launch-ready before the product earns launch readiness.
