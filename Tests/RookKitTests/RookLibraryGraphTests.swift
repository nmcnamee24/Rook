import Foundation
import Testing

@testable import RookKit

struct RookLibraryGraphTests {
  @Test
  func socialFeatureRequestRoutesToDeliberateForgeWork() {
    let decision = LocalRookRouter.route(
      "Hey Rook, can you work on adding a new following system for my social media app?")
    #expect(decision.destination == .deliberate)
    #expect(decision.response.pawns.contains { $0.pawn == "Forge" })
  }

  @Test
  func codexMemoryCatalogSeedsExistingProjectsAndActivity() throws {
    let (library, config, root) = try temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let markdown = """
      # Task Group: Jock profile and chat work
      scope: Use for Jock frontend profile, feed, and chat work.
      applies_to: cwd=/Users/example/Projects/jock; reuse_rule=verify the live route.
      - rollout_summaries/jock-profile.md
      ### keywords
      - JockLynx, profile, feed, chat-v2, messaging

      # Task Group: Jock deployment work
      scope: Use for the Jock app deployment and profile routes.
      applies_to: cwd=/Users/example/Projects/jock; reuse_rule=verify the production host.
      - rollout_summaries/jock-deploy.md
      - rollout_summaries/jock-verify.md
      ### keywords
      - Jock, deployment, profile, friends
      """

    let count = try library.importProjectCatalog(
      markdown: markdown,
      sourceDate: Date(timeIntervalSince1970: 1_786_554_000)
    )
    #expect(count == 1)
    let graph = library.graph()
    let jock = try #require(graph.nodes.first { $0.kind == .project && $0.title == "Jock" })
    #expect(jock.mentionCount == 3)
    #expect(jock.aliases.contains("JockLynx"))
    #expect(jock.aliases.contains("Jocks Links"))
    #expect(jock.referencedWorkspacePaths == ["/Users/example/Projects/jock"])
    #expect(jock.referencedSourceContexts.count == 2)
    #expect(jock.referencedSourceContexts.contains { $0.title == "Jock profile and chat work" })
    #expect(jock.referencedSourceContexts.contains { $0.body.contains("reuse_rule=verify the production host") })

    let social = try #require(graph.children(of: jock.id).first { $0.title == "Social Media" })
    let topics = Set(graph.children(of: social.id).map(\.title))
    #expect(topics.contains("Messaging"))
    #expect(topics.contains("Profiles"))
    #expect(topics.contains("Feed"))
    #expect(!social.referencedSourceContexts.isEmpty)

    let note = try String(
      contentsOf: config.libraryURL.appendingPathComponent(jock.notePath),
      encoding: .utf8
    )
    #expect(note.contains("## Stored source context"))
    #expect(note.contains("### Jock deployment work"))

    let snapshot = library.contextSnapshot(for: "Add following to my social media app")
    #expect(snapshot.contains("Recorded project workspaces: `/Users/example/Projects/jock`"))
    #expect(library.resolveProjectReference("Play some music") == nil)
  }

  @Test
  func catalogRebuildArchivesOnlyStaleGeneratedNodes() throws {
    let (library, config, root) = try temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = """
      # Task Group: Market chat work
      scope: Build profile and chat-v2 routes.
      applies_to: cwd=/Users/example/Projects/market; reuse_rule=verify live files.
      - rollout_summaries/market-chat.md
      """
    let corrected = """
      # Task Group: Market data work
      scope: Build the market data pipeline.
      applies_to: cwd=/Users/example/Projects/market; reuse_rule=verify live files.
      - rollout_summaries/market-data.md
      """

    _ = try library.importProjectCatalog(
      markdown: first,
      sourceDate: Date(timeIntervalSince1970: 1_786_554_000)
    )
    let project = try #require(library.graph().nodes.first { $0.kind == .project })
    let social = try #require(library.graph().children(of: project.id).first { $0.title == "Social Media" })
    let originalNote = config.libraryURL.appendingPathComponent(social.notePath)
    #expect(FileManager.default.fileExists(atPath: originalNote.path))
    let generatedOrphan = config.libraryNodesURL.appendingPathComponent("old-generated.md")
    let customNote = config.libraryNodesURL.appendingPathComponent("my-own-note.md")
    try RookConfig.writePrivate(
      Data("---\nid: topic:old\nkind: topic\n---\n# Old\n".utf8),
      to: generatedOrphan
    )
    try RookConfig.writePrivate(Data("# My own note\n".utf8), to: customNote)

    _ = try library.importProjectCatalog(
      markdown: corrected,
      sourceDate: Date(timeIntervalSince1970: 1_786_554_600)
    )
    #expect(library.graph().nodes.contains { $0.id == social.id } == false)
    #expect(FileManager.default.fileExists(atPath: originalNote.path) == false)
    let archivedNote = config.libraryURL
      .appendingPathComponent(".orphaned-nodes")
      .appendingPathComponent(social.notePath)
    #expect(FileManager.default.fileExists(atPath: archivedNote.path))
    #expect(FileManager.default.fileExists(atPath: generatedOrphan.path) == false)
    #expect(
      FileManager.default.fileExists(
        atPath: config.libraryURL.appendingPathComponent(".orphaned-nodes/nodes/old-generated.md").path
      ))
    #expect(FileManager.default.fileExists(atPath: customNote.path))
  }

  @Test
  func socialProjectBuildsAnObsidianStyleHierarchyAndResolvesImplicitly() throws {
    let (library, config, root) = try temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_786_554_000)
    let turnID = UUID()

    _ = try library.beginTurn(
      id: turnID,
      command: "I'm working on a social media app called Jocks Links.",
      route: "deliberate",
      pawns: [],
      now: now.addingTimeInterval(-600)
    )
    let entry = try library.finishTurn(
      id: turnID,
      command: "I'm working on a social media app called Jocks Links.",
      route: "deliberate",
      displayText: "Added group chats under the messaging system.",
      pawns: [],
      now: now.addingTimeInterval(-590)
    )

    let graph = library.graph()
    let project = try #require(graph.nodes.first { $0.kind == .project && $0.title == "Jocks Links" })
    let social = try #require(graph.children(of: project.id).first { $0.title == "Social Media" })
    let messaging = try #require(graph.children(of: social.id).first { $0.title == "Messaging" })

    #expect(graph.nodes.contains { $0.title == "Group Chats" } == false)
    #expect(messaging.aliases.contains("group chats"))
    #expect(entry.referencedNodeIDs.contains(project.id))
    #expect(entry.referencedNodeIDs.contains(social.id))
    #expect(entry.referencedNodeIDs.contains(messaging.id))

    let resolution = try #require(
      library.resolveProjectReference(
        "Hey Rook, can you add a new following system for my social media app?",
        now: now
      ))
    #expect(resolution.project.id == project.id)
    #expect(resolution.confidence == .high)
    #expect(resolution.path.map(\.title).contains("Social Media"))

    let snapshot = library.contextSnapshot(
      for: "Hey Rook, can you add a new following system for my social media app?",
      now: now
    )
    #expect(snapshot.contains("Library project graph resolved: [[Jocks Links]]"))
    #expect(snapshot.contains("[[Social Media]]"))
    #expect(snapshot.contains("[[Messaging]]"))

    let projectNote = config.libraryURL.appendingPathComponent(project.notePath)
    #expect(FileManager.default.fileExists(atPath: projectNote.path))
    let markdown = try String(contentsOf: projectNote, encoding: .utf8)
    #expect(markdown.contains("[[nodes/projects/jocks-links/social-media/index|Social Media]]"))
    #expect(FileManager.default.fileExists(atPath: config.libraryGraphURL.path))
  }

  @Test
  func mostWorkedOnProjectWinsWhenMultipleProjectsShareACategory() throws {
    let (library, _, root) = try temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_786_554_000)

    try archive(
      library,
      command: "I'm working on a social media app called Side Circle.",
      result: "Created the profile shell.",
      now: now.addingTimeInterval(-8_000)
    )
    for offset in 0..<4 {
      try archive(
        library,
        command: offset == 0
          ? "I'm working on a social media app called Jocks Links."
          : "Add messaging improvements to Jocks Links.",
        result: "Finished another Jocks Links messaging pass.",
        now: now.addingTimeInterval(TimeInterval(-4_000 + offset * 600))
      )
    }

    let resolution = try #require(
      library.resolveProjectReference("Add following to my social media app", now: now))
    #expect(resolution.project.title == "Jocks Links")
    #expect(resolution.reason.contains("dominate"))
  }

  @Test
  func equallyPlausibleProjectsRemainUnresolved() throws {
    let (library, _, root) = try temporaryLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_786_554_000)

    try archive(
      library,
      command: "I'm working on a social media app called Side Circle.",
      result: "Created messaging.",
      now: now.addingTimeInterval(-700)
    )
    try archive(
      library,
      command: "I'm working on a social media app called Jocks Links.",
      result: "Created messaging.",
      now: now.addingTimeInterval(-600)
    )

    #expect(library.resolveProjectReference("Update my social media app", now: now) == nil)
  }

  private func archive(
    _ library: RookLibrary,
    command: String,
    result: String,
    now: Date
  ) throws {
    let id = UUID()
    _ = try library.beginTurn(id: id, command: command, route: "deliberate", pawns: [], now: now)
    _ = try library.finishTurn(
      id: id,
      command: command,
      route: "deliberate",
      displayText: result,
      pawns: [],
      now: now.addingTimeInterval(10)
    )
  }

  private func temporaryLibrary() throws -> (RookLibrary, RookConfig, URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("rook-library-graph-tests-\(UUID().uuidString)", isDirectory: true)
    var config = RookConfig.recommended
    config.stateDirectory = root.appendingPathComponent("core", isDirectory: true).path
    try config.ensureStateDirectory()
    return (try RookLibrary(config: config), config, root)
  }
}
