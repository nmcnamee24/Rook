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

#### Measurement checkpoint implemented

- Live voice, typed, and mobile requests now share one request ID and private monotonic trace under `~/.codex/rook/core/traces`.
- The trace covers wake detection, first and final transcript, prompt refinement, intent and route selection, adapter start, external outcome, verification, classified failure, selected recovery, and completion.
- `Rook --benchmark-routing` runs the initial deterministic route suite without taking external action. The suite currently covers Spotify resume, Safari navigation, the dependent Spotify/artist request, coding handoff, and Reflex calculation.
- `Rook --record-manual-baseline <scenario> <milliseconds>` stores repeated manual comparison samples; `Rook --trace-summary` reports recent first-attempt success, median/p95 outcome time, route counts, and failure counts.
- Routing tests now require the Spotify compound request to remain Spotify-native for playback and now-playing inspection, wait on those results before artist research, and avoid Computer Operator. Safari URL navigation is also recognized by the narrow native controller.

This checkpoint proves routing ownership and makes live outcomes measurable.

#### Native execution checkpoint implemented

- `RookTaskExecutor` now runs eligible Spotify-owned hybrid steps before dependent pawn work and records each step as pending, running, succeeded, failed, blocked, or skipped.
- Playback requests are issued once. Rook verifies their result with a read-only Spotify player check, rejects stale player state whose track or context does not match the requested target, and retries that read at most once.
- Now-playing receipts contain only bounded track, artist, device, playback-state, and source facts. Those verified facts are supplied to central Rook for dependent Scout research; raw Spotify payloads, tokens, and account identifiers are not included.
- A failed or unverified prerequisite prevents its dependent steps from starting. Authentication, provider, ambiguity, rate-limit, and verification failures retain their specific category and never fall through to Computer Use.
- Playlist clarifications preserve the complete hybrid request. A short answer selects the playlist, resumes native execution, verifies the resulting track, and only then releases artist research.
- The final synthesis preserves the verified Spotify Canvas alongside the research response.

The executor is intentionally narrow. It proves the complete planner-to-native-to-research loop for Spotify, while other hybrid capability combinations continue through central Rook until they receive an equally explicit adapter and verification contract. Live latency and first-attempt success still require real user runs; mocked tests cannot prove provider reliability or subjective usefulness.

#### Fast-path acceptance checkpoint implemented

- `Rook --fast-path-readiness` now evaluates deterministic ownership, warm stable-intent-to-adapter latency, retry-aware first-attempt success, verified outcomes, forbidden Central/pawn/Computer-Use fallthrough, manual utility, and safe streaming preparation. Missing evidence is reported as `needs_data`, never as a pass.
- The acceptance suite requires 100 completed live runs for each reviewed fast-path scenario, five manual samples or an explicit attention-advantage note, and 20 live side-effect-free streaming prewarms. The reviewed scenarios are Spotify resume, Safari navigation, app launch, and Reflex calculation.
- `Rook --run-fast-path-scenario-once <scenario>` performs exactly one user-selected live native action and writes the normal private trace. It never loops external actions. The deterministic route suite now also enforces the 250-millisecond local-routing ceiling and includes app launch.
- Progressive voice input may privately precompute only a stable Reflex calculation or conversion after 350 milliseconds of transcript stability and at least 250 milliseconds of microphone quiet. Alerts, device changes, Spotify, browser/app control, screen capture, weather, and every semantic or compound request still wait. A prepared value is used only when the final transcript resolves to the identical intent.
- Every direct capability now declares an adapter, effect, retry rule, verification requirement, and whether a bounded receipt may feed dependent work. This gives weather, Reflex, screen capture, native Mac control, and Library-backed work explicit non-Spotify contracts without letting the exact gate interpret compound requests.
- Direct Spotify requests now use the mutation-once verified adapter. Native app launch verifies the returned running application, Safari navigation verifies the front-document destination with bounded read-only checks, and basic disconnected Spotify control verifies play/pause state when possible.

The first real one-action run on August 17 started the Reflex, Notes, Safari, and Spotify adapters within 5.5 milliseconds of the stable benchmark command. Reflex and Notes completed and verified; Safari verification passed on one run and missed on another before its bounded verification window was extended; Spotify reached its authoritative API but the provider rejected resume. There are still no manual baseline samples and no live voice streaming-prewarm samples. These results establish the measurement path, not the 99% or manual-advantage product gate.

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

#### Rook-owned detector checkpoint implemented

- Rook now has an isolated local LiveKit WakeWord/ONNX process and a pinned Swift dependency for a Rook-owned classifier. Detection and audio remain local; the process emits only readiness, phrase, confidence, and sample timing.
- Apple SpeechAnalyzer remains continuously active for command transcription, so acoustic wake detection does not restart recognition or drop the first word in “Rook, open…”. The previous Apple wake matcher remains an explicitly labeled compatibility fallback until the local runtime and validated model are present.
- A 1.2-second memory-only PCM ring protects the wake boundary, and command endpointing now learns the current room floor instead of requiring the old fixed `0.12` meter level. This makes quiet speech testable without lowering one global threshold for noisy rooms.
- `make enroll-wake` records private user training samples; production training adds 25,000 synthetic positives, hard phonetic negatives, general speech, background noise, and reverberation. Held-out corpus recording is separate from training.
- `make promote-wake` refuses to activate a candidate until there are at least 20 samples and 95% recall in every required profile, at least 24 hours of negative audio, and no more than one false activation per 24 hours. Its report is bound to the exact model SHA-256 so replacing a model invalidates the gate.
- The runtime, training recipe, and model are locally ownable and need no account or runtime fee. Until the user records the complete corpus and a candidate passes it, this checkpoint does not claim that whisper/noise reliability has been proven on the target Mac.

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

#### Live FluidAudio trial checkpoint implemented

- Rook now performs a second, on-device transcription of each captured voice command with FluidAudio 0.15.3 and the English Parakeet TDT v2 high-recall model before routing the command.
- Apple SpeechAnalyzer remains active for wake-boundary continuity, live transcript feedback, endpointing, and immediate fallback. Command audio is bounded to 45 seconds, retained only in memory, and never written to disk by the trial.
- The trial is enabled by default in this build and can be reversed immediately from the menu-bar item **FluidAudio Transcription (Trial)**. If its model is still preparing, returns no usable text, or fails, Rook sends the Apple transcript instead.
- Final-transcript traces identify `fluidaudio_v2_trial` versus `apple_speech` and record only a generic fallback category, not the spoken content.
- The signed installed app loaded the local model successfully on August 18 and reported `FluidAudio trial ready`. This proves the integration and fallback path are live, not that FluidAudio is yet better for Noah's commands. Natural daily use and correction observations are the next evidence; the formal representative corpus remains deferred until it is worth the time.

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

#### Deliberator design direction

The deliberator should produce a compact, inspectable execution contract rather than an unconstrained internal essay:

1. intended outcome and constraints;
2. ordered steps with explicit dependencies;
3. one authoritative owner for each step: Reflex/native adapter, central Rook, or pawn-eligible work;
4. verification criteria for each external outcome; and
5. a bounded recovery decision based on the observed failure category.

Ambiguity should trigger the smallest useful clarification. Authentication and permission failures should name the exact setup boundary. Transient provider failures may retry the same authoritative adapter once when the action is safe to repeat. Policy blocks must wait for approval. Dependency failures stop downstream work. Other execution failures escalate for diagnosis without silently changing the user's goal or switching a supported native domain to Computer Use.

Rook may learn from repeated traces only by proposing a reviewed, versioned routing rule with a regression test. A single failure must never silently rewrite behavior, expand authority, or create a hidden permanent preference.

### P0: Coding must not be a weaker Codex

#### Observation

Rook's coding path is currently less capable than opening Codex directly. If it uses a weaker model, reduced context, restricted tools, an incorrect checkout, or extra orchestration that does not improve the result, Rook adds friction without adding value.

#### Product decision

Rook should not attempt to replace Codex's coding agent. It should be the voice, context, routing, and approval layer that hands coding work to a full-strength Codex task in the correct repository and then presents its progress and result coherently.

#### Acceptance bar

- A coding request routed through Rook receives the same repository context, model class, tool access, and verification expectations as the equivalent direct Codex request unless Rook displays a specific safety reason for a restriction.
- Rook's added latency is limited to intent/context preparation and does not serialize work that Codex can perform directly.
- Comparative evaluations use the same prompt and checkout through both paths and score correctness, completeness, elapsed time, and required user intervention.

#### Full Codex handoff checkpoint implemented

- The Central delegator now has one explicit `coding` intent. It remains the semantic front door, but returns no Forge plan for coding work; the host hands the intact request to one full Codex task instead of running a parallel Rook coding subsystem.
- Rook requires one graph-resolved live checkout under the user's home folder. Missing or ambiguous workspace ownership stops at a concise project clarification rather than defaulting to private Rook state.
- The coding task uses a non-ephemeral Codex app-server thread in that checkout and deliberately omits Rook's background model and structured response schema, allowing the task to inherit normal Codex configuration and repository instructions.
- Rook persists the request/thread mapping, checkout, lifecycle state, bounded final summary, and interruption or failure reason under private state. The shared Activity view distinguishes Codex tasks from pawn crews and shows only generic non-sensitive progress.
- Completed Codex output returns through central Rook with the saved task identifier and checkout. A focused CLI diagnostic exercises the same handoff directly.

This checkpoint establishes one coding owner and a durable continuation point. It does not yet prove parity with direct Codex; the same real coding prompt still needs to be run through both paths and scored for correctness, completeness, elapsed time, verification, and required user intervention.

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

## 2026-08-14 — Rook as the personal AI control plane

This entry records the decisions and implementation direction developed in the shared [Rook hosting and capability conversation](https://chatgpt.com/share/6a7f542c-4d14-83ea-9649-3d90a058d7c5), reconciled against the current repository rather than copied forward as a greenfield architecture.

### Governing product decision

Rook should be one persistent personal intelligence that routes work across devices, services, models, agents, and tools without making the user understand that machinery.

Rook is not an AI toolkit, MCP dashboard, connector manager, or weaker replacement for its underlying agents. It is the user-facing control plane above them:

- one identity;
- one memory and continuity layer;
- one interface and voice;
- one coherent set of abilities;
- all available devices and services; and
- one central owner for user-visible answers, action authority, and final synthesis.

The design test for every consumer-facing surface is:

> Would the user need to understand how Rook works in order to use this?

If the answer is yes, redesign the surface or move the implementation detail into Developer Mode.

The accompanying safety rule is:

> Hide complexity, not consequences.

Rook should hide MCP servers, APIs, models, nodes, context files, tool schemas, and agent plumbing during ordinary use. It must still show the exact recipient, destination, content, time, cost, scope, or destructive effect before a consequential commitment. Increased architectural sophistication must never silently broaden authority.

### Working architecture direction

Rook should become a distributed system rather than a cloud-only application or a process tied permanently to one open laptop window.

The intended layers are:

1. **Rook experience** — voice, typed commands, concise answers, Canvas, contextual connection prompts, and exact approvals.
2. **Rook intelligence layer** — identity, Library context, continuity, planning, capability and skill selection, permissions, dependency handling, verification, and recovery.
3. **Infrastructure** — native adapters, provider APIs, MCP servers, models, Codex, databases, relays, and device nodes.

Only the first layer should normally be visible. The bottom layers may be complex, but that complexity should make the top simpler and more predictable.

The current working hosting direction is:

- an always-on headless Rook Core owns durable task and conversation state;
- the Windows PC is the likely first always-on Core host after the host service is made cross-platform;
- the Mac advertises local capabilities whenever it is online;
- the existing iPhone client reaches the authoritative Core through Rook's integrated encrypted transport rather than requiring a consumer-facing VPN or Tailscale installation;
- Mac-specific work becomes explicitly unavailable when the Mac is offline while provider, Library, and other host-owned work may continue; and
- managed cloud fallback, automatic Core election, and seamless failover remain later milestones rather than initial requirements.

The Mac is therefore not merely where Rook runs. It becomes one capability-bearing device Rook can use when available.

### Capability and MCP decision

Rook should have one internal capability registry spanning:

- reviewed native adapters;
- provider APIs;
- MCP servers;
- Mac, Windows, phone, and future device-node capabilities;
- Codex and other specialist agents; and
- read-only context resources.

Every registered capability should declare at least:

- stable identity and authoritative owner;
- adapter type and node or provider location;
- bounded input and result schemas;
- domain and skill tags;
- authentication and availability state;
- read, write, destructive, and consequential risk;
- required approval or user handoff;
- retry and idempotency behavior; and
- verification criteria and attributable evidence.

MCP is a useful internal peripheral bus, not the product. Rook should eventually speak standards-compliant MCP so a reviewed server can register capabilities without bespoke routing code. Rook must not dump every connected tool definition into every model request, automatically trust or install arbitrary servers, or equate protocol compatibility with safe product support.

The scale objective is not “support 10,000 MCP servers.” It is:

> Discover, authenticate, permission, rank, and invoke the right compatible capability only when it is needed.

A mature registry may know about thousands of capabilities while an individual deep request normally receives only the smallest relevant subset, approximately five to twenty.

### Just-in-time skill decision

Rook's core identity, action policy, privacy boundaries, and central ownership rules must always be present. Domain instructions should be just-in-time.

The intended selection flow is:

1. continuity preflight resolves an open answer, retry, approval follow-up, or unique recent referent;
2. an exact fully claimed native request may use the reviewed direct capability guide;
3. every other request reaches the no-tools Central Rook delegator intact;
4. Central evaluates compact skill and capability metadata and chooses the smallest sufficient deep-work plan;
5. a deep session loads only the top one to three complete domain skills;
6. the registry exposes only capabilities that are relevant, authenticated, permitted, and online;
7. Library retrieval supplies only relevant project and personal context; and
8. execution returns verified receipts for final Central synthesis.

The local exact gate must not become a semantic keyword router for skills or pawns. A UI-design request may load UI and design-system skills plus Figma, browser, and screenshot capabilities. A scheduling request should not see those instructions or tools at all.

### Connection experience decision

Ordinary users should see connection bundles such as:

- Continue with Google;
- Connect GitHub;
- Connect Spotify;
- Pair this Mac; or
- Pair this PC.

Missing access should normally appear in context when the requested outcome needs it. Production onboarding should use Rook-owned OAuth registrations and one browser login. Bring-your-own client IDs, scopes, callbacks, raw MCP setup, and provider diagnostics belong in Developer Mode.

#### Spotify consumer connection checkpoint implemented

- The ordinary Spotify card now shows **Connect Spotify** and immediately opens the existing system-browser PKCE flow. Connected users see **Manage** and **Disconnect**; they never handle a Client ID, callback, scope, authorization code, or token.
- Release builds may inject a Rook-owned public Spotify Client ID into the app bundle. Existing private developer overrides remain backward compatible, and a build with no configured app identity exposes the developer setup instead of starting a broken sign-in.
- The authorization boundary is unchanged: S256 PKCE, random state validation, the fixed `127.0.0.1` callback, Keychain-only access and refresh tokens, no client secret, and no Spotify mutation scopes.
- This UX change does not bypass Spotify Development Mode. Premium, allowlist, quota, and active-device requirements still produce explicit provider or setup failures rather than falling through to Codex, pawns, or Computer Use.

Provider authorization never changes Rook's action authority. A technically broad provider scope remains constrained by Rook's duplicate, conflict, attendee, recurrence, deletion, send, publish, purchase, and other approval rules.

### Current repository reality

The repository already implements important parts of this thesis:

- a thin continuity and exact-capability gate followed by Central-first semantic routing;
- one user-visible Central Rook with silent bounded pawns;
- the Library, graph context, action queue, monotonic traces, and classified recovery;
- reviewed direct Reflex, weather, Spotify, screen-capture, and narrow Mac-control paths;
- native Google and Spotify OAuth scaffolding with direct Spotify execution;
- encrypted nearby and internet-relayed iPhone access while preserving Mac authority; and
- explicit approval and privacy boundaries.

The plan must preserve those systems rather than replace them with an older keyword router, a VPN-first mobile design, or a generic tool-loading layer.

The material gaps are:

- `Package.swift` remains macOS-only and the authoritative orchestration lifecycle is still coupled to `RookAppDelegate`;
- there is no generic capability registry spanning native adapters, nodes, provider APIs, MCP, and agents;
- there is no generic MCP client and trust adapter;
- domain skills are not yet selected and loaded through a bounded JIT registry;
- the Mac remains the execution authority and Rook cannot continue independently when it is offline;
- native Gmail and Calendar data clients remain incomplete; and
- Google still exposes developer OAuth setup; Spotify now has the consumer one-click path when a Rook app identity is bundled.

The shared conversation also described an integration and skills workbook containing 151 capability rows, connection bundles, gateway comparisons, and 33 candidate JIT skills. The public share exposes only the workbook summary, not a downloadable `.xlsx` artifact. Treat that inventory as a future prioritization input, not as an implemented or immediately committed backlog.

## Ordered implementation plan

The intended dependency order is:

> indispensable workflow → capability and skill kernel → consumer connections → headless Core → Mac node → Windows host → bounded MCP scale

### Milestone 1: Prove one indispensable workflow on the current system

Before beginning a platform rewrite, prove that Rook can deliver one outcome that is meaningfully better than using Codex or the individual applications manually.

The initial target workflow is:

> From voice or iPhone, inspect the latest relevant Rook GitHub issue, resolve the correct checkout, ask full-strength Codex to fix it on the Mac, run the relevant verification, preserve progress and evidence, and report the result without committing, pushing, or messaging unless the exact action is separately authorized.

Required behavior:

- resolve the correct issue, project, checkout, and execution environment;
- use full-strength Codex rather than a weaker coding substitute;
- preserve explicit dependencies between issue retrieval, local work, tests, and reporting;
- classify authentication, node-offline, execution, dependency, and verification failures accurately;
- issue every mutation once and prevent duplicate work after retries or reconnects; and
- retain exact approval gates for commit, push, publish, or external messaging.

Exit gate:

- a repeatable end-to-end soak suite has zero wrong targets, duplicate mutations, unauthorized external actions, or false completion claims;
- every run records route, owner, evidence, verification state, latency, and user correction count; and
- the workflow is useful enough that the user would choose Rook over opening the underlying tools directly.

### Milestone 2: Build the capability and JIT-skill kernel

Implement the registry contract and adapt the existing reviewed capabilities into it before adding a broad MCP surface.

Required work:

- define capability, availability, permission, receipt, and verification schemas in `RookKit`;
- keep the existing exact direct-capability guide as the no-model fast path;
- expose compact skill and capability metadata to Central Rook;
- load no more than the selected one to three complete domain skills for deep work;
- filter capability exposure by relevance, authentication, permission, trust, and online state;
- keep action policy and Central ownership outside optional domain skills; and
- add regression coverage proving that irrelevant skills and tools never enter the request context.

Exit gate:

- UI work does not receive Calendar or inbox capabilities;
- scheduling work does not receive Figma, frontend, database, or coding instructions;
- an offline node's capabilities cannot be selected as available;
- a semantic or compound request still reaches Central intact; and
- selecting a skill cannot expand the user's authority.

### Milestone 3: Replace developer setup with consumer connection bundles

Prioritize depth in a few services rather than connection count:

1. complete guarded native Gmail and Calendar data paths behind the existing Google authorization;
2. add GitHub issue and repository context for the indispensable coding workflow;
3. preserve and harden the existing direct Spotify path; and
4. present paired computers as simple available or unavailable devices.

Required work:

- establish Rook-owned OAuth registrations for product use;
- move client-ID entry, scope details, callbacks, and raw diagnostics into Developer Mode;
- request missing access in the context of the user's intended outcome;
- keep tokens and account identifiers out of Codex prompts, Library records, speech, Canvas, traces, and pawn work; and
- keep provider scopes narrower than necessary whenever practical while enforcing Rook policy even when a provider grants broader technical access.

Exit gate:

- a new user can connect each supported provider through one recognizable browser-login flow;
- no normal workflow requires handling a client ID, API key, MCP server, callback URL, or scope string; and
- disconnect, token refresh, revoked access, and insufficient-scope failures are correctly classified and recoverable.

### Milestone 4: Extract an always-on headless Rook Core

Move durable orchestration out of the AppKit window lifecycle before attempting a Windows port.

The headless service should own:

- request and conversation state;
- Central delegation and deep-session launch;
- Library, graph, task, and approval state;
- capability and skill registries;
- scheduling and background checkpoints;
- provider selection and connection state; and
- node registration and task receipts.

The macOS command-center application becomes a client of that service while retaining Mac-specific UI, voice, capture, and local controls.

Exit gate:

- closing the Rook window does not stop an accepted task;
- reopening the UI reattaches to authoritative progress and results;
- restarting the UI does not duplicate an operation; and
- the service can start at login without requiring the Codex application window to remain open.

The first extracted host may continue using the locally authenticated Codex runtime as an inference provider. Provider abstraction should make that an implementation choice rather than Rook's product identity.

### Milestone 5: Introduce the Mac node contract

The Mac should advertise reviewed local capabilities to the Core rather than exposing an unrestricted remote shell.

The node protocol requires:

- deliberate pairing and stable device identity;
- version negotiation and a heartbeat;
- capability advertisement with current availability;
- encrypted and authenticated requests;
- replay protection and idempotency keys;
- cancellation and deadline propagation;
- explicit pending, running, succeeded, failed, blocked, and skipped state;
- bounded structured results and attributable verification receipts; and
- node-local enforcement of permission and privacy rules.

Begin with read-only operations and narrow existing adapters. Add writes only after each capability has an exact mutation, retry, and verification contract.

Exit gate:

- disconnecting the Mac marks its capabilities unavailable without killing Rook;
- reconnecting restores the reviewed capability inventory automatically;
- an uncertain outcome is never repeated as though it definitely failed; and
- reconnect or host restart cannot lose or duplicate an accepted operation.

### Milestone 6: Run the Core continuously on the Windows PC

Port the headless host service, not the macOS application.

Expected behavior:

- the Windows PC starts Rook Core automatically and holds authoritative durable state;
- the Mac joins as a local-capability node whenever available;
- the iPhone reaches the current authority through Rook's integrated nearby or encrypted relay path;
- non-Mac provider and Library work continues while the Mac is closed;
- Mac-specific requests return a precise unavailable state or an explicitly supported alternative; and
- reopening the Mac restores its capabilities without moving credentials to the phone or relay.

Exit gate:

- an iPhone request reaches the Windows-hosted Core and uses the Mac when the required capability is online;
- closing the Mac does not make Rook itself disappear;
- reopening the Mac restores its advertised capabilities and resumes only tasks whose state makes resumption safe; and
- the relay, phone, and remote host never receive unnecessary Mac, provider, Codex, or filesystem credentials.

Automatic Mac/Windows/cloud leader election is not part of this milestone. One configured authority is preferable to premature distributed consensus.

### Milestone 7: Add bounded MCP support and Developer Mode

After the registry, permissions, receipts, and JIT selection are stable, implement MCP as one capability adapter.

Start with five to ten reviewed services or servers. Each must have:

- a known source and trust level;
- explicit authentication and permission mapping;
- bounded schema ingestion;
- capability tags and selection tests;
- action-risk classification;
- result verification or an honest unverified state; and
- safe disconnect and revocation behavior.

Do not automatically discover and install arbitrary servers during ordinary task execution. Compatibility may make a capability available for review; it does not grant trust or authority.

Developer Mode may expose:

- execution traces and dependency state;
- selected skills and capability candidates;
- MCP and native adapter manifests;
- node availability and protocol versions;
- model and provider calls;
- context retrieval and memory writes;
- latency, tokens, failures, and retries; and
- permissions, approvals, and verification receipts.

This surface is analogous to a browser's Web Inspector. It is essential for building Rook but is not Rook's normal interface.

Exit gate:

- a new reviewed MCP server can register without new semantic routing code;
- its capabilities appear only in relevant, permitted requests;
- untrusted or offline servers cannot be selected;
- connecting a server does not enlarge action authority; and
- ordinary users never need to know whether the result came from MCP, a native API, a node, or an agent.

## Explicit non-goals for the current roadmap

Do not build yet:

- all 151 workbook integrations;
- a public MCP marketplace;
- automatic MCP installation or trust decisions;
- automatic Mac, Windows, and cloud Core election;
- a complete cloud migration;
- a required consumer VPN or Tailscale setup;
- custom foundation models;
- physical Rook hardware;
- multi-user and enterprise administration;
- more Pawns or broad new capability categories before the P0 workflows pass; or
- a consumer dashboard centered on tools, agents, tokens, server status, or infrastructure.

## Roadmap gate

The platform roadmap does not supersede the August 13 utility and reliability reset. Wake reliability, transcription accuracy, fast-path latency, full-strength coding handoff, and first-attempt task success remain P0 requirements.

The correct sequence is therefore:

> prove usefulness and reliability on the current system → extract the reusable control-plane kernel → move authority off the Mac → scale integrations behind the invisible product surface

Rook earns the right to become a platform only after its first narrow workflows are boringly reliable and meaningfully better than using the underlying tools directly.
