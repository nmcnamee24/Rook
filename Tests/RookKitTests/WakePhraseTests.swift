import XCTest

@testable import RookKit

final class WakePhraseTests: XCTestCase {
  func testPromptRefinerRemovesFillersAndRepeatedStarts() {
    XCTAssertEqual(
      RookPromptRefiner.refine("Um, I want to I want to, like, clean up this prompt"),
      "I want to clean up this prompt."
    )
  }

  func testPromptRefinerPreservesSemanticLikeAndProtectedTokens() {
    XCTAssertEqual(
      RookPromptRefiner.refine("I like Swift 6.2 and do not change /tmp/RookConfig.swift"),
      "I like Swift 6.2 and do not change /tmp/RookConfig.swift"
    )
    XCTAssertEqual(
      RookPromptRefiner.refine("npm run test with gpt-5.6 on iPhone"),
      "npm run test with gpt-5.6 on iPhone"
    )
    XCTAssertEqual(
      RookPromptRefiner.refine("Show examples like Swift and Rust"),
      "Show examples like Swift and Rust."
    )
  }

  func testPromptRefinerRemovesNaturalVoiceFillersWithoutAModel() {
    XCTAssertEqual(
      RookPromptRefiner.refine(
        "So basically I know we worked on Like the canvas where it can show, um, the, Like the weather But now there's, like, there's no way to show generated images"
      ),
      "I know we worked on the canvas where it can show the weather, but now there's no way to show generated images."
    )
    XCTAssertEqual(
      RookPromptRefiner.refine("Well, can you, you know, clean up this prompt"),
      "Can you clean up this prompt?"
    )
    XCTAssertEqual(
      RookPromptRefiner.refine("format it into an actual prompt instead of leaving it like raw transcription"),
      "Format it into an actual prompt instead of leaving it as raw transcription."
    )
  }

  func testPromptRefinerFormatsSpokenParagraphsAndBullets() {
    XCTAssertEqual(
      RookPromptRefiner.refine(
        "write a launch plan new paragraph bullet point test the build bullet point preserve user changes"
      ),
      "Write a launch plan\n\n- Test the build\n- Preserve user changes"
    )
  }

  func testPromptRefinerRejectsModelRewriteThatDropsProtectedMeaning() {
    XCTAssertNil(
      RookPromptRefiner.validatedModelPolish(
        "Change the config.",
        preserving: "Do not change /tmp/config.json before 10:30"
      )
    )
    XCTAssertEqual(
      RookPromptRefiner.validatedModelPolish(
        "Do not change /tmp/config.json before 10:30.",
        preserving: "Um, do not change /tmp/config.json before 10:30"
      ),
      "Do not change /tmp/config.json before 10:30."
    )
  }

  func testPromptRefinerUsesModelOnlyForLongOrMessySpeech() {
    XCTAssertFalse(
      RookPromptRefiner.needsModelPolish(
        original: "Open Safari",
        locallyRefined: "Open Safari."
      )
    )
    XCTAssertTrue(
      RookPromptRefiner.needsModelPolish(
        original: "Um I want you to first inspect the current code and then fix the prompt formatting issue",
        locallyRefined: "I want you to first inspect the current code and then fix the prompt formatting issue."
      )
    )
  }

  func testDetectsRecommendedWakePhrase() {
    XCTAssertTrue(WakePhrase.contains("Rook, wake up", phrase: "rook wake up"))
    XCTAssertTrue(WakePhrase.contains("hey ROOK wake-up please", phrase: "rook wake up"))
    XCTAssertTrue(WakePhrase.contains("Brooke wake up", phrase: "rook wake up"))
    XCTAssertTrue(WakePhrase.contains("Book, wake up", phrase: "rook wake up"))
  }

  func testExtractsCommandAfterWakePhrase() {
    XCTAssertEqual(
      WakePhrase.commandTail(in: "Rook, wake up. What's on my calendar?", phrase: "rook wake up"),
      "What's on my calendar"
    )
  }

  func testAcceptsNaturalRookForm() {
    XCTAssertTrue(WakePhrase.contains("Rook", phrase: "rook wake up"))
    XCTAssertEqual(WakePhrase.commandTail(in: "Rook", phrase: "rook wake up"), "")
    XCTAssertEqual(
      WakePhrase.commandTail(in: "Rook, what's next?", phrase: "rook wake up"),
      "what's next"
    )
  }

  func testPrefersFullPhraseBeforeBareRook() {
    XCTAssertEqual(
      WakePhrase.commandTail(in: "Rook wake up, plan my day", phrase: "rook wake up"),
      "plan my day"
    )
  }

  func testBareRookAcceptsObservedSpeechAliasesAtStart() {
    XCTAssertEqual(
      WakePhrase.commandTail(in: "Brooke can you hear everything I am saying", phrase: "Rook"),
      "can you hear everything I am saying"
    )
    XCTAssertEqual(
      WakePhrase.commandTail(in: "Hey Brook, plan tomorrow", phrase: "Rook"),
      "plan tomorrow"
    )
  }

  func testBareRookDoesNotWakeOnOrdinaryMention() {
    XCTAssertNil(WakePhrase.commandTail(in: "The rook moves in a straight line", phrase: "Rook"))
    XCTAssertNil(WakePhrase.commandTail(in: "I talked with Brooke yesterday", phrase: "Rook"))
  }

  func testResponseSchemaDecodes() throws {
    let json =
      #"{"display_text":"Done","spoken_text":"Done.","intent":"status","requires_approval":false,"queue_item_ids":[],"pawns":[]}"#
    let decoded = try JSONDecoder().decode(RookResponse.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.displayText, "Done")
    XCTAssertEqual(decoded.pawns, [])
    XCTAssertEqual(decoded.canvas, [])
  }

  func testQuickResponseRoutesRoutineConversationWithoutPawns() throws {
    let json =
      #"{"display_text":"Hey — what’s up?","spoken_text":"Hey, what’s up?","route":"answer_now","intent":"answer","pawns":[]}"#
    let decoded = try JSONDecoder().decode(QuickRookResponse.self, from: Data(json.utf8))
    XCTAssertFalse(decoded.needsDeliberation)
    XCTAssertEqual(decoded.immediateResponse.pawns, [])
    XCTAssertEqual(decoded.canvas, [])
  }

  func testQuickResponseShowsPlannedPawnsAsWorking() throws {
    let json =
      #"{"display_text":"I’m checking that now.","spoken_text":"I’m checking that now.","route":"deliberate","intent":"plan","pawns":[{"pawn":"Scout","task":"research the options"}]}"#
    let decoded = try JSONDecoder().decode(QuickRookResponse.self, from: Data(json.utf8))
    XCTAssertTrue(decoded.needsDeliberation)
    XCTAssertEqual(decoded.immediateResponse.pawns.first?.status, "working")
  }

  func testQueueLabelsStayHumanAndUnderFiveWords() {
    XCTAssertEqual(
      RookQueueLabel.make(kind: "calendar_update", title: "Move hike to 1:30 PM today"),
      "Move hike time"
    )
    XCTAssertEqual(
      RookQueueLabel.make(kind: "gmail_draft", title: "Meeting notes for design review"),
      "Draft meeting notes"
    )
    XCTAssertEqual(
      RookQueueLabel.make(
        kind: "calendar_update",
        title: "Ignored",
        explicitLabel: "Move the product planning meeting"
      ),
      "Move the product planning"
    )
  }

  func testLegacyConfigGetsFastLayerAndPerPromptCrewDefaults() throws {
    let json =
      #"{"wake_phrase":"Rook","language":"en-US","on_device_only":true,"silence_seconds":0.7,"follow_up_window_seconds":3,"voice":"Samantha","voice_rate":225,"model":"gpt-5.6-terra","reasoning_effort":"high","max_pawns":3,"codex_path":"/tmp/codex","queue_script_path":"/tmp/queue.py","state_directory":"/tmp/rook"}"#
    let decoded = try JSONDecoder().decode(RookConfig.self, from: Data(json.utf8))
    XCTAssertEqual(decoded.frontReasoningEffort, "low")
    XCTAssertEqual(decoded.reasoningEffort, "high")
    XCTAssertEqual(decoded.frontModel, "gpt-5.6-luna")
    XCTAssertFalse(decoded.promptPolishEnabled)
    XCTAssertEqual(decoded.promptPolishWaitMilliseconds, 900)
    XCTAssertEqual(decoded.speechEngine, "kokoro")
    XCTAssertEqual(decoded.neuralVoice, "bm_daniel")
    XCTAssertEqual(decoded.neuralVoiceSpeed, 0.96)
    XCTAssertEqual(decoded.wakePhrase, "Rook")
    XCTAssertEqual(decoded.mobileRelayURL, "")
    XCTAssertEqual(decoded.normalizedEnabledPawns, PawnDefinition.defaultNames)
    XCTAssertEqual(decoded.effectiveMaxPawns, RookConfig.pawnCapacityPerPrompt)
  }

  func testPawnRolesCannotBeDisabledAndCapacityMigratesToPerPromptCrew() {
    var config = RookConfig.recommended
    config.enabledPawns = ["Auditor", "Scout", "Unknown", "Scout"]
    config.maxPawns = 2

    config.normalizePawnSettings()

    XCTAssertEqual(config.enabledPawns, PawnDefinition.defaultNames)
    XCTAssertEqual(config.maxPawns, RookConfig.pawnCapacityPerPrompt)
    XCTAssertEqual(config.effectiveMaxPawns, RookConfig.pawnCapacityPerPrompt)
  }

  func testAllPawnRolesRemainAvailableWhenLegacyConfigDisabledThem() {
    var config = RookConfig.recommended
    config.enabledPawns = []
    config.maxPawns = 0
    let bridge = CodexBridge(config: config)

    let quick = bridge.sanitized(
      QuickRookResponse(
        displayText: "I’m on it.",
        spokenText: "I’m on it.",
        route: "deliberate",
        intent: "plan",
        pawns: [PawnPlan(pawn: "Scout", task: "Research", id: "scout_1")]
      ))
    let deep = bridge.sanitized(
      RookResponse(
        displayText: "Done",
        spokenText: "Done.",
        intent: "status",
        requiresApproval: false,
        queueItemIDs: [],
        pawns: [PawnReport(pawn: "Scout", task: "Research", status: "completed", id: "scout_1")]
      ))

    XCTAssertEqual(config.effectiveMaxPawns, RookConfig.pawnCapacityPerPrompt)
    XCTAssertEqual(quick.pawns.map(\.pawn), ["Scout"])
    XCTAssertEqual(deep.pawns.map(\.pawn), ["Scout"])
  }

  func testBridgeAllowsDuplicateRolesAndAssignsUniqueInstanceIDs() {
    let bridge = CodexBridge(config: .recommended)
    let response = RookResponse(
      displayText: "Done",
      spokenText: "Done.",
      intent: "status",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [
        PawnReport(pawn: "Steward", task: "Check calendar", status: "completed"),
        PawnReport(pawn: "Steward", task: "Create work block", status: "completed"),
        PawnReport(pawn: "Scribe", task: "Create document", status: "completed", id: "scribe_1"),
        PawnReport(pawn: "Auditor", task: "Verify conflicts", status: "completed"),
      ]
    )

    let pawns = bridge.sanitized(response).pawns
    XCTAssertEqual(pawns.map(\.pawn), ["Steward", "Steward", "Scribe", "Auditor"])
    XCTAssertEqual(Set(pawns.compactMap(\.id)).count, pawns.count)
    XCTAssertEqual(pawns[0].instanceLabel, "Steward 1")
    XCTAssertEqual(pawns[1].instanceLabel, "Steward 2")
    XCTAssertEqual(pawns[2].instanceLabel, "Scribe 1")
  }

  func testBridgeCapsEachPromptCrewAtTenInstances() {
    let bridge = CodexBridge(config: .recommended)
    let reports = (1...12).map { index in
      PawnReport(
        pawn: index.isMultiple(of: 2) ? "Scout" : "Auditor",
        task: "Work stream \(index)",
        status: "working"
      )
    }
    let response = RookResponse(
      displayText: "Working",
      spokenText: "Working.",
      intent: "status",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: reports
    )

    let pawns = bridge.sanitized(response).pawns
    XCTAssertEqual(pawns.count, RookConfig.pawnCapacityPerPrompt)
    XCTAssertEqual(Set(pawns.compactMap(\.id)).count, RookConfig.pawnCapacityPerPrompt)
  }

  func testResponseSchemasAllowTenPawnInstancesWithStableIDs() {
    XCTAssertTrue(QuickRookResponse.outputSchema.contains(#""maxItems": 10"#))
    XCTAssertTrue(QuickRookResponse.outputSchema.contains(#""id""#))
    XCTAssertTrue(RookResponse.outputSchema.contains(#""maxItems": 10"#))
    XCTAssertTrue(RookResponse.outputSchema.contains(#""id""#))
    XCTAssertTrue(RookResponse.outputSchema.contains(#""result""#))
    XCTAssertTrue(RookResponse.outputSchema.contains(#""evidence""#))
  }

  func testCanvasSchemasAreValidAndAdvertiseRichRenderers() throws {
    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(QuickRookResponse.outputSchema.utf8)))
    XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(RookResponse.outputSchema.utf8)))
    for kind in ["weather", "calendar", "image", "code", "diagram", "list", "computer"] {
      XCTAssertTrue(RookResponse.outputSchema.contains("\"\(kind)\""))
    }
    XCTAssertTrue(RookResponse.outputSchema.contains(#""computer""#))
    XCTAssertTrue(RookResponse.outputSchema.contains(#""canvas""#))
  }

  func testInstantComputerParserRecognizesBrowserSearch() {
    XCTAssertEqual(
      RookComputerCommandParser.parse("Open Safari and search for American University events"),
      .webSearch(browser: .safari, query: "American University events")
    )
    XCTAssertEqual(
      RookComputerCommandParser.parse("Search for weather tomorrow using Chrome"),
      .webSearch(browser: .chrome, query: "weather tomorrow")
    )
  }

  func testInstantComputerParserRecognizesNarrowAppAndSpotifyControls() {
    XCTAssertEqual(
      RookComputerCommandParser.parse("Open Notes"),
      .openApplication(name: "Notes")
    )
    XCTAssertEqual(RookSpotifyCommandParser.parse("Pause Spotify"), .pause)
    XCTAssertEqual(RookSpotifyCommandParser.parse("Next track on Spotify"), .next)
    XCTAssertEqual(RookSpotifyCommandParser.parse("Play my Spotify"), .resume)
    XCTAssertEqual(RookSpotifyCommandParser.parse("Open Spotify and play my music"), .resume)
  }

  func testCompoundCommandsStayScreenAwareAndNamedPlaylistsUseTheCapabilityGuide() {
    XCTAssertNil(RookComputerCommandParser.parse("Open Notes and delete the old draft"))
    XCTAssertNil(RookComputerCommandParser.parse("Open Safari and search for headphones and buy them"))
    XCTAssertNil(RookComputerCommandParser.parse("Play my Focus playlist on Spotify"))
    XCTAssertNil(RookComputerCommandParser.parse("Open Terminal and run a command"))

    XCTAssertEqual(
      RookDirectCapabilityGuide.resolve("Play my Focus playlist on Spotify"),
      .spotify(.play(query: "Focus", preferredKind: .playlist, libraryOnly: true))
    )
  }

  func testWebAddressParserAllowsHTTPButRejectsEmbeddedCredentials() {
    XCTAssertEqual(
      RookComputerCommandParser.parse("Open openai.com in Safari"),
      .openWebAddress(browser: .safari, address: "openai.com")
    )
    XCTAssertNil(RookComputerCommandParser.parse("Open https://noah:secret@example.com"))
  }

  func testCanvasSanitizerRejectsUnsafeImagesAndKeepsVerifiedPanels() {
    let bridge = CodexBridge(config: .recommended)
    let response = RookResponse(
      displayText: "Forecast ready",
      spokenText: "Forecast ready.",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        RookCanvasBlock(
          id: "bad_image",
          kind: .image,
          title: "Unsafe image",
          imageURL: "http://localhost/private.png"
        ),
        RookCanvasBlock(
          id: "weather_panel",
          kind: .weather,
          title: "Three-day forecast",
          items: [
            RookCanvasItem(id: "today", label: "Today", detail: "Sunny", value: "80°", symbol: .sun)
          ],
          sourceLabel: "Forecast",
          sourceURL: "https://example.com/weather"
        ),
      ]
    )

    let canvas = bridge.sanitized(response).canvas
    XCTAssertEqual(canvas.map(\.kind), [.weather])
    XCTAssertEqual(canvas.first?.sourceURL, "https://example.com/weather")
  }

  func testCanvasSanitizerKeepsPublicOnlineImagesAndRemovesTrackingParameters() throws {
    let bridge = CodexBridge(config: .recommended)
    let response = RookResponse(
      displayText: "Reference ready",
      spokenText: "Reference ready.",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        RookCanvasBlock(
          id: "online_image",
          kind: .image,
          title: "Capybara",
          imageURL: "https://images.example.com/capybara.png?utm_source=rook&width=1200",
          caption: "A public online reference",
          sourceLabel: "Example",
          sourceURL: "https://example.com/gallery?utm_campaign=canvas"
        )
      ]
    )

    let block = try XCTUnwrap(bridge.sanitized(response).canvas.first)
    XCTAssertEqual(block.imageURL, "https://images.example.com/capybara.png?width=1200")
    XCTAssertEqual(block.sourceURL, "https://example.com/gallery")
    XCTAssertNotNil(RookImageSourceValidator.publicHTTPSURL("https://fda.gov/reference.png"))
    XCTAssertNil(RookImageSourceValidator.publicHTTPSURL("https://127.0.0.1/private.png"))
    XCTAssertNil(RookImageSourceValidator.publicHTTPSURL("https://[fd00::1]/private.png"))
    XCTAssertNil(RookImageSourceValidator.publicHTTPSURL("https://user:secret@example.com/image.png"))
    XCTAssertNil(RookImageSourceValidator.publicHTTPSURL("https://example.com/image.png?token=secret"))
  }

  func testCodexGeneratedImageIsCapturedAndAttachedAsPrivateCanvasAsset() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-media-tests-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    var config = RookConfig.recommended
    config.stateDirectory = root.appendingPathComponent("core", isDirectory: true).path
    try config.ensureStateDirectory()

    let onePixelPNG =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    let event: [String: Any] = [
      "type": "item.completed",
      "item": [
        "type": "mcp_tool_call",
        "result": [
          "content": [
            ["type": "image", "data": onePixelPNG, "mimeType": "image/png"]
          ]
        ],
      ],
    ]
    let eventData = try JSONSerialization.data(withJSONObject: event)
    let eventLine = try XCTUnwrap(String(data: eventData, encoding: .utf8))
    let store = RookMediaStore(rootURL: config.mediaURL)
    let assetID = try XCTUnwrap(store.storeImages(fromCodexJSONL: eventLine).first)
    XCTAssertNotNil(store.imageURL(for: assetID))

    let rolloutEvent: [String: Any] = [
      "type": "event_msg",
      "payload": [
        "type": "image_generation_end",
        "status": "completed",
        "result": onePixelPNG,
      ],
    ]
    let rolloutData = try JSONSerialization.data(withJSONObject: rolloutEvent)
    let rolloutLine = try XCTUnwrap(String(data: rolloutData, encoding: .utf8))
    let rolloutAssetID = try XCTUnwrap(store.storeImages(fromCodexJSONL: rolloutLine).first)
    XCTAssertNotNil(store.imageURL(for: rolloutAssetID))

    let response = RookResponse(
      displayText: "I made the image.",
      spokenText: "I made it.",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        RookCanvasBlock(
          id: "generated_image",
          kind: .image,
          title: "Generated concept",
          caption: "Created for this request"
        )
      ]
    )
    let canvas = CodexBridge(config: config).sanitized(
      response,
      generatedImageAssetIDs: [assetID]
    ).canvas
    XCTAssertEqual(canvas.first?.imageAssetID, assetID)
    XCTAssertEqual(canvas.first?.imageURL, "")

    let invented = RookCanvasBlock(
      id: "invented_asset",
      kind: .image,
      title: "Invented",
      imageAssetID: assetID
    )
    let rejected = CodexBridge(config: config).sanitized(
      RookResponse(
        displayText: "No",
        spokenText: "No.",
        intent: "brief",
        requiresApproval: false,
        queueItemIDs: [],
        pawns: [],
        canvas: [invented]
      )
    )
    XCTAssertTrue(rejected.canvas.isEmpty)
  }

  func testCanvasRoundTripsWithTheLastResponsePayload() throws {
    let response = RookResponse(
      displayText: "Calendar ready",
      spokenText: "Calendar ready.",
      intent: "brief",
      requiresApproval: false,
      queueItemIDs: [],
      pawns: [],
      canvas: [
        RookCanvasBlock(
          id: "calendar_panel",
          kind: .calendar,
          title: "Your calendar",
          items: [
            RookCanvasItem(
              id: "event_1",
              label: "Project meeting",
              symbol: .calendar,
              start: "2026-08-11T14:00:00-04:00",
              end: "2026-08-11T15:00:00-04:00"
            )
          ]
        )
      ]
    )

    let decoded = try JSONDecoder().decode(RookResponse.self, from: JSONEncoder().encode(response))
    XCTAssertEqual(decoded, response)
    XCTAssertFalse(RookResponse.outputSchema.contains("image_asset_id"))
  }

  func testVisualRequestsRouteToDeepRook() {
    for command in [
      "Show me the three day forecast",
      "Bring up a picture of a capybara",
      "Draw a diagram of this workflow",
    ] {
      let decision = LocalRookRouter.route(command)
      XCTAssertEqual(decision.destination, .deliberate)
      XCTAssertTrue(decision.response.pawns.contains { $0.pawn == "Scout" })
    }
  }

  func testBasicWeatherCommandsUseTheNativeRequestParser() {
    XCTAssertEqual(
      RookWeatherCommandParser.parse("What's the weather?"),
      RookWeatherRequest(locationQuery: nil, dayOffset: 0, dayCount: 1)
    )
    XCTAssertEqual(
      RookWeatherCommandParser.parse("Weather in Oakland, New Jersey over the next 3 days"),
      RookWeatherRequest(locationQuery: "Oakland, New Jersey", dayOffset: 0, dayCount: 3)
    )
    XCTAssertEqual(
      RookWeatherCommandParser.parse("What's the weather in New Jersey, Oakland, New Jersey, over the next 3 days"),
      RookWeatherRequest(locationQuery: "Oakland, New Jersey", dayOffset: 0, dayCount: 3)
    )
    XCTAssertEqual(
      RookWeatherCommandParser.parse("What's the temperature tomorrow in Boston"),
      RookWeatherRequest(locationQuery: "Boston", dayOffset: 1, dayCount: 1)
    )
  }

  func testWeatherDecisionsAndSafetyQuestionsStillDeliberate() {
    for command in [
      "Should we still hike even with the weather?",
      "Are there weather alerts near the beach?",
      "Compare the weather and tell me the best day to drive",
      "Rook can show weather on the Canvas, but can it show generated and online images too?",
    ] {
      XCTAssertNil(RookWeatherCommandParser.parse(command))
      XCTAssertEqual(LocalRookRouter.route(command).destination, .deliberate)
    }
  }

  func testLocalRouterAnswersCommonVoiceChecksWithoutAModel() {
    let greeting = LocalRookRouter.route("Hey Rook")
    let hearing = LocalRookRouter.route("Can you hear me?")

    XCTAssertEqual(greeting.destination, .instant)
    XCTAssertEqual(greeting.response.displayText, "Hey—what’s up?")
    XCTAssertEqual(hearing.destination, .instant)
    XCTAssertTrue(hearing.response.pawns.isEmpty)
  }

  func testLocalRouterStreamsStableOrdinaryQuestions() {
    let decision = LocalRookRouter.route("Why is the sky blue?")

    XCTAssertEqual(decision.destination, .stream)
    XCTAssertEqual(decision.response.displayText, "Thinking…")
    XCTAssertTrue(decision.response.pawns.isEmpty)
  }

  func testLocalRouterSendsLivePersonalWorkDirectlyToAPawnCrew() {
    let decision = LocalRookRouter.route(
      "Make a work block from my calendar, and create a document, and verify there are no conflicts."
    )
    let roles = Set(decision.response.pawns.map(\.pawn))

    XCTAssertEqual(decision.destination, .deliberate)
    XCTAssertTrue(roles.contains("Steward"))
    XCTAssertTrue(roles.contains("Scribe"))
    XCTAssertTrue(roles.contains("Auditor"))
  }

  func testLocalRouterCanDeployRepeatedRoleInstances() {
    let decision = LocalRookRouter.route(
      "Check my calendar and then move my hike, and check my email and then draft a reply."
    )
    let stewards = decision.response.pawns.filter { $0.pawn == "Steward" }

    XCTAssertEqual(decision.destination, .deliberate)
    XCTAssertGreaterThanOrEqual(stewards.count, 2)
    XCTAssertEqual(Set(stewards.compactMap(\.id)).count, stewards.count)
    XCTAssertEqual(Array(stewards.prefix(2)).map(\.id), ["steward_1", "steward_2"])
  }

  func testLocalRouterSendsPriorPawnAndBugFollowUpsToDeepRook() {
    let decision = LocalRookRouter.route(
      "I was talking about the link opening bug that Forge and Auditor said was interrupted and blocked."
    )
    let roles = Set(decision.response.pawns.map(\.pawn))

    XCTAssertEqual(decision.destination, .deliberate)
    XCTAssertTrue(roles.contains("Forge"))
    XCTAssertTrue(roles.contains("Auditor"))
  }

  func testBackgroundConnectorPolicyAllowsGuardedCalendarCreateUpdateAndGmailDraftWrites() {
    let overrides = Set(CodexBridge.backgroundAppConfigOverrides)

    XCTAssertTrue(
      overrides.contains(where: { $0.contains("connector_947e0d954944416db111db556030eea6.destructive_enabled=true") }))
    XCTAssertTrue(overrides.contains(where: { $0.contains("tools.create_event.approval_mode=\"approve\"") }))
    XCTAssertTrue(overrides.contains(where: { $0.contains("tools.update_event.enabled=true") }))
    XCTAssertTrue(overrides.contains(where: { $0.contains("tools.update_event.approval_mode=\"approve\"") }))
    XCTAssertTrue(overrides.contains(where: { $0.contains("tools.create_draft.approval_mode=\"approve\"") }))
    XCTAssertTrue(overrides.contains(where: { $0.contains("tools.update_draft.approval_mode=\"approve\"") }))

    for blockedTool in [
      "delete_event", "respond_event", "set_event_label_silently",
      "send_email", "send_draft", "forward_emails", "delete_emails",
    ] {
      XCTAssertTrue(
        overrides.contains(where: { $0.contains("tools.\(blockedTool).enabled=false") }),
        "Expected \(blockedTool) to be disabled for background Rook"
      )
    }
  }

  func testBackgroundCodexRequestsOnRequestApprovalPolicy() {
    XCTAssertEqual(CodexBridge.approvalPolicy(frontLayer: false), "on-request")
    XCTAssertEqual(CodexBridge.approvalPolicy(frontLayer: true), "untrusted")
  }

  func testLibrarianIsSeparateFromPromptCrewsAndOwnsContextPawns() {
    XCTAssertFalse(PawnDefinition.defaultNames.contains("Librarian"))
    XCTAssertFalse(QuickRookResponse.outputSchema.contains("Librarian"))
    XCTAssertFalse(RookResponse.outputSchema.contains("Librarian"))
    XCTAssertTrue(RookCheckpoint.outputSchema.contains("context_pawns"))
    XCTAssertTrue(RookCheckpoint.outputSchema.contains("Steward"))

    let decision = LocalRookRouter.route("Why was the previous Forge task interrupted?")
    XCTAssertEqual(decision.destination, .deliberate)
    XCTAssertFalse(decision.response.pawns.contains { $0.pawn == "Librarian" })
    XCTAssertTrue(decision.response.pawns.contains { $0.pawn == "Scout" })
    XCTAssertLessThanOrEqual(decision.response.pawns.count, RookConfig.pawnCapacityPerPrompt)
  }

  func testLibraryCreatesConversationAndPawnTaskFolders() throws {
    let (library, config) = try temporaryLibrary()
    let id = UUID()
    _ = try library.beginTurn(
      id: id,
      command: "Investigate the calendar conflict",
      route: "deliberate",
      pawns: [
        PawnPlan(pawn: "Steward", task: "check calendar", id: "steward_1"),
        PawnPlan(pawn: "Librarian", task: "index result", id: "librarian_1"),
      ]
    )
    let entry = try library.finishTurn(
      id: id,
      command: "Investigate the calendar conflict",
      route: "deliberate",
      displayText: "The conflict was resolved.",
      pawns: [
        PawnReport(
          pawn: "Steward",
          task: "checked calendar",
          status: "completed",
          id: "steward_1",
          result: "Found one overlapping event and verified the bounded target window.",
          evidence: ["Primary Calendar read for the requested day", "One overlapping event"]
        )
      ]
    )

    XCTAssertEqual(entry.status, .completed)
    XCTAssertEqual(entry.label, "Investigate the calendar conflict")
    XCTAssertFalse(entry.pawns.contains { $0.pawn == "Librarian" })
    XCTAssertNotNil(entry.librarianIndexedAt)
    XCTAssertNotNil(entry.taskFolder)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: entry.conversationFolder).appendingPathComponent("summary.md").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: URL(fileURLWithPath: entry.taskFolder!).appendingPathComponent("pawns.json").path))
    XCTAssertEqual(
      entry.pawns.first?.reportedResult, "Found one overlapping event and verified the bounded target window.")
    XCTAssertEqual(entry.pawns.first?.reportedEvidence.count, 2)
    let reports = try JSONDecoder().decode(
      [PawnReport].self,
      from: Data(contentsOf: URL(fileURLWithPath: entry.taskFolder!).appendingPathComponent("pawns.json"))
    )
    XCTAssertEqual(reports.first?.reportedEvidence.last, "One overlapping event")
    let summary = try String(
      contentsOf: URL(fileURLWithPath: entry.taskFolder!).appendingPathComponent("summary.md"),
      encoding: .utf8
    )
    XCTAssertTrue(summary.contains("## Task pawns"))
    XCTAssertTrue(summary.contains("### Steward 1"))
    XCTAssertTrue(summary.contains("**Result**"))
    XCTAssertTrue(summary.contains("**Evidence**"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: config.libraryIndexURL.path))
  }

  func testLibraryPreservesBlockReasonForRetrieval() throws {
    let (library, _) = try temporaryLibrary()
    let id = UUID()
    _ = try library.beginTurn(
      id: id,
      command: "Fix the link opening bug",
      route: "deliberate",
      pawns: [PawnPlan(pawn: "Forge", task: "fix link", id: "forge_1")]
    )
    _ = try library.failTurn(
      id: id,
      command: "Fix the link opening bug",
      route: "deliberate",
      displayText: "The deeper pass stopped.",
      reason: "Codex runtime exited before Forge finished.",
      pawns: [PawnReport(pawn: "Forge", task: "fix link", status: "working", id: "forge_1")]
    )

    let snapshot = library.contextSnapshot(for: "Why was the link bug blocked and interrupted?")
    XCTAssertTrue(snapshot.contains("Fix the link opening"))
    XCTAssertTrue(snapshot.contains("Codex runtime exited before Forge finished."))
    XCTAssertTrue(snapshot.contains("Librarian indexed:"))
  }

  func testCentralContextIncludesExactActiveQueueStateForApprovalBinding() throws {
    let (library, config) = try temporaryLibrary()
    let queue = #"""
      {
        "version": 1,
        "next_id": 8,
        "items": [
          {
            "id": "RQ-0007",
            "kind": "message_send",
            "label": "Send love text",
            "title": "Text Sophia",
            "details": "Recipient: Sophia; exact text: You mean the world to me.",
            "proposed_action": "Send the reviewed text through Messages",
            "risk": "medium",
            "status": "approved",
            "created_at": "2026-08-13T00:10:00Z",
            "expires_at": "2099-08-16T00:10:00Z"
          }
        ]
      }
      """#
    try RookConfig.writePrivate(Data(queue.utf8), to: config.actionQueueURL)

    let snapshot = library.contextSnapshot(for: "yes send the text to Sophia")
    XCTAssertTrue(snapshot.contains("Exact action queue snapshot for central Rook only"))
    XCTAssertTrue(snapshot.contains("RQ-0007 | approved | Send love text"))
    XCTAssertTrue(snapshot.contains("Recipient: Sophia; exact text:"))
  }

  func testLibraryResolvesImmediateRetryToRecentSpotifyRequest() throws {
    let (library, _) = try temporaryLibrary()
    let now = Date(timeIntervalSince1970: 1_786_494_600)
    let id = UUID()
    _ = try library.beginTurn(
      id: id,
      command: "Play my Spotify",
      route: "computer_native",
      pawns: [],
      now: now.addingTimeInterval(-30)
    )
    _ = try library.failTurn(
      id: id,
      command: "Play my Spotify",
      route: "computer_native",
      displayText: "Spotify needed permission.",
      reason: "Automation permission was unavailable.",
      pawns: [],
      now: now.addingTimeInterval(-20)
    )

    let resolution = try XCTUnwrap(library.resolveConversationReference("Hey Rook, try that again.", now: now))
    XCTAssertEqual(resolution.effectiveCommand, "Play my Spotify")
    XCTAssertEqual(resolution.referencedTurnID, id)
    XCTAssertTrue(resolution.displayCommand.contains("Play my Spotify"))
  }

  func testTopicQualifiedRetrySurvivesContextSwitching() throws {
    let (library, _) = try temporaryLibrary()
    let now = Date(timeIntervalSince1970: 1_786_494_600)
    let spotifyID = UUID()
    _ = try library.beginTurn(
      id: spotifyID,
      command: "Play my Spotify",
      route: "computer_native",
      pawns: [],
      now: now.addingTimeInterval(-600)
    )
    _ = try library.finishTurn(
      id: spotifyID,
      command: "Play my Spotify",
      route: "computer_native",
      displayText: "Spotify is playing.",
      pawns: [],
      now: now.addingTimeInterval(-590)
    )
    let weatherID = UUID()
    _ = try library.beginTurn(
      id: weatherID,
      command: "Show tomorrow's weather",
      route: "weather_native",
      pawns: [],
      now: now.addingTimeInterval(-60)
    )
    _ = try library.finishTurn(
      id: weatherID,
      command: "Show tomorrow's weather",
      route: "weather_native",
      displayText: "Tomorrow is sunny.",
      pawns: [],
      now: now.addingTimeInterval(-50)
    )

    let resolution = try XCTUnwrap(library.resolveConversationReference("Try Spotify again", now: now))
    XCTAssertEqual(resolution.effectiveCommand, "Play my Spotify")
    XCTAssertEqual(resolution.referencedTurnID, spotifyID)
  }

  func testGenericRetryDoesNotReachIntoStaleContext() throws {
    let (library, _) = try temporaryLibrary()
    let now = Date(timeIntervalSince1970: 1_786_494_600)
    let id = UUID()
    _ = try library.beginTurn(
      id: id,
      command: "Open Notes",
      route: "computer_native",
      pawns: [],
      now: now.addingTimeInterval(-3 * 3_600)
    )
    _ = try library.finishTurn(
      id: id,
      command: "Open Notes",
      route: "computer_native",
      displayText: "Notes opened.",
      pawns: [],
      now: now.addingTimeInterval(-3 * 3_600)
    )

    XCTAssertNil(library.resolveConversationReference("Try that again", now: now))
  }

  func testContextSnapshotAlwaysCarriesRecentConversationThread() throws {
    let (library, _) = try temporaryLibrary()
    let now = Date(timeIntervalSince1970: 1_786_494_600)
    let id = UUID()
    _ = try library.beginTurn(
      id: id,
      command: "Play my Spotify",
      route: "computer_native",
      pawns: [],
      now: now.addingTimeInterval(-30)
    )
    _ = try library.finishTurn(
      id: id,
      command: "Play my Spotify",
      route: "computer_native",
      displayText: "Spotify resumed.",
      pawns: [],
      now: now.addingTimeInterval(-20)
    )

    let snapshot = library.contextSnapshot(for: "What were we doing?", now: now)
    XCTAssertTrue(snapshot.contains("Recent conversation thread, newest first:"))
    XCTAssertTrue(snapshot.contains("user asked: Play my Spotify"))
  }

  func testRepeatedMeetingPrepBecomesActivePreference() throws {
    let (library, _) = try temporaryLibrary()
    try library.observePreferences(
      command: "Can you make notes before my project meeting?",
      turnID: UUID(),
      label: "Project meeting notes"
    )
    XCTAssertFalse(library.activePreferences().contains { $0.id == "meeting_preparation" })

    try library.observePreferences(
      command: "Please prepare a brief for my next meeting",
      turnID: UUID(),
      label: "Prepare meeting brief"
    )
    let preference = try XCTUnwrap(library.activePreferences().first { $0.id == "meeting_preparation" })
    XCTAssertEqual(preference.evidenceCount, 2)
    XCTAssertFalse(preference.isExplicit)
  }

  func testExplicitLocationIsLearnedImmediately() throws {
    let (library, _) = try temporaryLibrary()
    try library.observePreferences(
      command: "My location is Arlington, Virginia.",
      turnID: UUID(),
      label: "Set home location"
    )
    let location = try XCTUnwrap(library.activePreferences().first { $0.id == "home_location" })
    XCTAssertEqual(location.value, "Arlington, Virginia")
    XCTAssertTrue(location.isExplicit)
  }

  func testFreshCheckpointAnswersReadOnlyOperationalQuestionsLocally() throws {
    let (library, _) = try temporaryLibrary()
    let now = Date()
    let checkedAt = ISO8601DateFormatter().string(from: now)
    try library.storeCheckpoint(
      RookCheckpoint(
        checkedAt: checkedAt,
        timezone: "America/New_York",
        calendarAsOf: checkedAt,
        calendarItems: [
          RookCheckpointEvent(
            title: "Project meeting",
            start: "2:00 PM",
            end: "3:00 PM",
            location: "Zoom"
          )
        ],
        gmailAsOf: checkedAt,
        emailItems: [
          RookCheckpointEmail(
            sender: "Maya",
            subject: "Project follow-up",
            receivedAt: "11:20 AM",
            whyItMatters: "A reply may be needed today"
          )
        ],
        suggestions: [],
        preparations: []
      ), now: now)

    let decision = try XCTUnwrap(library.cachedOperationalDecision(for: "What is on my calendar?", now: now))
    XCTAssertEqual(decision.destination, .instant)
    XCTAssertTrue(decision.response.displayText.contains("Project meeting"))
    XCTAssertTrue(decision.response.displayText.contains("Want me to check for anything newer?"))
    XCTAssertEqual(decision.response.canvas.first?.kind, .calendar)
    XCTAssertEqual(decision.response.canvas.first?.items.first?.label, "Project meeting")
    XCTAssertNil(library.cachedOperationalDecision(for: "Refresh my calendar right now", now: now))
  }

  func testCheckpointConnectorPolicyIsReadOnly() {
    let overrides = Set(CodexBridge.checkpointAppConfigOverrides)
    for blockedTool in ["create_event", "update_event", "create_draft", "update_draft", "send_email"] {
      XCTAssertTrue(
        overrides.contains(where: { $0.contains("tools.\(blockedTool).enabled=false") }),
        "Expected \(blockedTool) to be disabled during a checkpoint"
      )
    }
  }

  private func temporaryLibrary() throws -> (RookLibrary, RookConfig) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-library-tests-\(UUID().uuidString)", isDirectory: true)
    var config = RookConfig.recommended
    config.stateDirectory = root.appendingPathComponent("core", isDirectory: true).path
    try config.ensureStateDirectory()
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (try RookLibrary(config: config), config)
  }
}
