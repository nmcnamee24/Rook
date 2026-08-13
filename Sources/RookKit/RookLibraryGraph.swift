import Foundation

public enum RookLibraryNodeKind: String, Codable, CaseIterable, Sendable {
  case project
  case category
  case topic
}

public enum RookLibraryEdgeKind: String, Codable, Sendable {
  case contains
  case relatedTo = "related_to"
}

public struct RookLibraryNodeContext: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let source: String
  public let title: String
  public let body: String
  public let updatedAt: Date

  public init(id: String, source: String, title: String, body: String, updatedAt: Date) {
    self.id = id
    self.source = source
    self.title = title
    self.body = body
    self.updatedAt = updatedAt
  }
}

public struct RookLibraryNode: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let kind: RookLibraryNodeKind
  public var title: String
  public var aliases: [String]
  public var keywords: [String]
  public var mentionCount: Int
  public let createdAt: Date
  public var updatedAt: Date
  public var turnIDs: [UUID]
  public var notePath: String
  public var workspacePaths: [String]?
  public var sourceContexts: [RookLibraryNodeContext]?

  public var referencedWorkspacePaths: [String] { workspacePaths ?? [] }
  public var referencedSourceContexts: [RookLibraryNodeContext] { sourceContexts ?? [] }

  public init(
    id: String,
    kind: RookLibraryNodeKind,
    title: String,
    aliases: [String] = [],
    keywords: [String] = [],
    mentionCount: Int = 0,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    turnIDs: [UUID] = [],
    notePath: String,
    workspacePaths: [String]? = nil,
    sourceContexts: [RookLibraryNodeContext]? = nil
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.aliases = aliases
    self.keywords = keywords
    self.mentionCount = mentionCount
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.turnIDs = turnIDs
    self.notePath = notePath
    self.workspacePaths = workspacePaths
    self.sourceContexts = sourceContexts
  }
}

public struct RookLibraryEdge: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let sourceID: String
  public let targetID: String
  public let kind: RookLibraryEdgeKind
  public var weight: Int
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    sourceID: String,
    targetID: String,
    kind: RookLibraryEdgeKind,
    weight: Int = 1,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = "\(sourceID)->\(targetID):\(kind.rawValue)"
    self.sourceID = sourceID
    self.targetID = targetID
    self.kind = kind
    self.weight = weight
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct RookLibraryGraph: Codable, Equatable, Sendable {
  public var version: Int
  public var updatedAt: Date
  public var nodes: [RookLibraryNode]
  public var edges: [RookLibraryEdge]

  public init(
    version: Int = 3,
    updatedAt: Date = Date(),
    nodes: [RookLibraryNode] = [],
    edges: [RookLibraryEdge] = []
  ) {
    self.version = version
    self.updatedAt = updatedAt
    self.nodes = nodes
    self.edges = edges
  }

  public func node(id: String) -> RookLibraryNode? {
    nodes.first { $0.id == id }
  }

  public func children(of nodeID: String) -> [RookLibraryNode] {
    let childIDs = Set(edges.filter { $0.sourceID == nodeID && $0.kind == .contains }.map(\.targetID))
    return nodes.filter { childIDs.contains($0.id) }.sorted { $0.title < $1.title }
  }

  public func parents(of nodeID: String) -> [RookLibraryNode] {
    let parentIDs = Set(edges.filter { $0.targetID == nodeID && $0.kind == .contains }.map(\.sourceID))
    return nodes.filter { parentIDs.contains($0.id) }.sorted { $0.title < $1.title }
  }
}

public struct RookProjectResolution: Equatable, Sendable {
  public enum Confidence: String, Equatable, Sendable {
    case high
    case medium
  }

  public let project: RookLibraryNode
  public let confidence: Confidence
  public let reason: String
  public let path: [RookLibraryNode]

  public init(
    project: RookLibraryNode,
    confidence: Confidence,
    reason: String,
    path: [RookLibraryNode]
  ) {
    self.project = project
    self.confidence = confidence
    self.reason = reason
    self.path = path
  }
}

final class RookLibraryGraphStore: @unchecked Sendable {
  private struct ConceptRule {
    let title: String
    let aliases: [String]
  }

  private struct ProjectCandidate {
    let project: RookLibraryNode
    let semanticScore: Int
    let totalScore: Int
    let matchedNodeIDs: [String]
  }

  private struct CatalogSeed {
    var path: String
    var title: String
    var aliases: [String]
    var evidence: String
    var activityCount: Int
    var contexts: [RookLibraryNodeContext]
  }

  private let config: RookConfig
  private let fileManager = FileManager.default

  private static let categoryRules = [
    ConceptRule(title: "Social Media", aliases: ["social media", "social network", "social app"]),
    ConceptRule(title: "Mobile", aliases: ["mobile", "iphone", "ios", "android"]),
    ConceptRule(title: "Web", aliases: ["web", "website", "frontend", "backend"]),
    ConceptRule(title: "Data", aliases: ["data", "database", "analytics", "pipeline"]),
  ]

  // The concepts are intentionally broad. For example, group chats add evidence
  // to Messaging instead of creating a separate node for every message shape.
  private static let topicRules = [
    ConceptRule(
      title: "Messaging",
      aliases: [
        "messaging", "message", "messages", "chat", "chats", "group chat", "group chats", "direct message", "dm",
      ]
    ),
    ConceptRule(title: "Friends", aliases: ["friend", "friends", "friendship", "friend request", "friend requests"]),
    ConceptRule(title: "Following", aliases: ["following", "follow", "follows", "follower", "followers"]),
    ConceptRule(title: "Profiles", aliases: ["profile", "profiles", "account page"]),
    ConceptRule(title: "Feed", aliases: ["feed", "timeline", "posts"]),
    ConceptRule(title: "Authentication", aliases: ["authentication", "auth", "login", "sign in", "oauth"]),
    ConceptRule(title: "Payments", aliases: ["payment", "payments", "billing", "checkout", "stripe"]),
    ConceptRule(title: "Deployment", aliases: ["deployment", "deploy", "hosting", "vercel", "railway"]),
  ]

  private static let strongSocialCatalogSignals = [
    "social media", "social network", "social app", "chat v2", "group chat", "direct message", "friend request",
    "friends", "followers", "follower",
  ]

  init(config: RookConfig) throws {
    self.config = config
    try Self.createPrivateDirectory(config.libraryNodesURL)
    if !fileManager.fileExists(atPath: config.libraryGraphURL.path) {
      try save(RookLibraryGraph())
    }
  }

  func load() throws -> RookLibraryGraph {
    guard fileManager.fileExists(atPath: config.libraryGraphURL.path) else {
      let graph = RookLibraryGraph()
      try save(graph)
      return graph
    }
    return try Self.decoder().decode(
      RookLibraryGraph.self,
      from: Data(contentsOf: config.libraryGraphURL)
    )
  }

  func associate(
    command: String,
    summary: String,
    turnID: UUID,
    existingNodeIDs: [String],
    now: Date
  ) throws -> [String] {
    var graph = try load()
    let nodeIDs = associate(
      command: command,
      summary: summary,
      turnID: turnID,
      existingNodeIDs: existingNodeIDs,
      now: now,
      graph: &graph
    )
    try save(graph)
    return nodeIDs
  }

  func backfill(entries: [RookLibraryEntry]) throws -> [UUID: [String]] {
    guard !entries.isEmpty else { return [:] }
    var graph = try load()
    var associations: [UUID: [String]] = [:]
    var changed = false
    let indexedTurns = Set(graph.nodes.flatMap(\.turnIDs))

    for entry in entries.sorted(by: { $0.updatedAt < $1.updatedAt }) {
      if !entry.referencedNodeIDs.isEmpty {
        associations[entry.id] = entry.referencedNodeIDs
        continue
      }
      if indexedTurns.contains(entry.id) {
        let ids = graph.nodes.filter { $0.turnIDs.contains(entry.id) }.map(\.id).sorted()
        if !ids.isEmpty { associations[entry.id] = ids }
        continue
      }
      let ids = associate(
        command: entry.command,
        summary: entry.summary,
        turnID: entry.id,
        existingNodeIDs: [],
        now: entry.updatedAt,
        graph: &graph
      )
      if !ids.isEmpty {
        associations[entry.id] = ids
        changed = true
      }
    }
    if changed { try save(graph) }
    return associations
  }

  func resolveProject(for query: String, now: Date) -> RookProjectResolution? {
    guard let graph = try? load() else { return nil }
    return Self.resolveProject(for: query, graph: graph, now: now)
  }

  @discardableResult
  func importCatalog(markdown: String, sourceDate: Date) throws -> Int {
    let seeds = Self.catalogSeeds(from: markdown, sourceDate: sourceDate)
    guard !seeds.isEmpty else { return 0 }
    var graph = try load()
    let original = graph
    var prunedNotePaths = Set<String>()

    for seed in seeds {
      let projectID = "project:\(Self.slug(Self.cleanProjectName(seed.title)))"
      prunedNotePaths.formUnion(pruneCatalogOnlyDescendants(projectID: projectID, graph: &graph))
      var project = upsertProject(named: seed.title, evidence: seed.evidence, now: sourceDate, graph: &graph)
      guard let projectOffset = graph.nodes.firstIndex(where: { $0.id == project.id }) else { continue }
      graph.nodes[projectOffset].aliases = Self.merged(
        graph.nodes[projectOffset].aliases,
        seed.aliases,
        limit: 20
      )
      graph.nodes[projectOffset].workspacePaths = Self.merged(
        graph.nodes[projectOffset].referencedWorkspacePaths,
        [seed.path],
        limit: 8
      )
      graph.nodes[projectOffset].mentionCount = max(
        graph.nodes[projectOffset].mentionCount,
        seed.activityCount
      )
      graph.nodes[projectOffset].sourceContexts = Self.mergedContexts(
        graph.nodes[projectOffset].referencedSourceContexts,
        seed.contexts,
        limit: 60
      )
      project = graph.nodes[projectOffset]

      let matchedTopics = Self.topicRules.filter { Self.matches(rule: $0, in: seed.evidence) }
      var matchedCategories = Self.categoryRules.filter { Self.matches(rule: $0, in: seed.evidence) }
      let normalizedEvidence = Self.normalized(seed.evidence)
      if Self.strongSocialCatalogSignals.contains(where: normalizedEvidence.contains),
        !matchedCategories.contains(where: { $0.title == "Social Media" })
      {
        matchedCategories.append(Self.categoryRules[0])
      }

      var categoryNodes: [RookLibraryNode] = []
      for rule in matchedCategories {
        let category = upsertConcept(
          rule: rule,
          kind: .category,
          parentID: project.id,
          turnID: nil,
          evidence: seed.evidence,
          now: sourceDate,
          graph: &graph
        )
        if let offset = graph.nodes.firstIndex(where: { $0.id == category.id }) {
          graph.nodes[offset].mentionCount = max(graph.nodes[offset].mentionCount, seed.activityCount)
          graph.nodes[offset].sourceContexts = Self.mergedContexts(
            graph.nodes[offset].referencedSourceContexts,
            seed.contexts.filter {
              Self.matches(rule: rule, in: $0.body)
                || (rule.title == "Social Media"
                  && Self.strongSocialCatalogSignals.contains(where: Self.normalized($0.body).contains))
            },
            limit: 40
          )
          categoryNodes.append(graph.nodes[offset])
        }
        upsertEdge(from: project.id, to: category.id, kind: .contains, now: sourceDate, graph: &graph)
      }

      let topicParent =
        categoryNodes.first(where: { $0.title == "Social Media" })
        ?? (categoryNodes.count == 1 ? categoryNodes[0] : nil)
      for rule in matchedTopics {
        let topic = upsertConcept(
          rule: rule,
          kind: .topic,
          parentID: topicParent?.id ?? project.id,
          turnID: nil,
          evidence: seed.evidence,
          now: sourceDate,
          graph: &graph
        )
        if let offset = graph.nodes.firstIndex(where: { $0.id == topic.id }) {
          graph.nodes[offset].mentionCount = max(graph.nodes[offset].mentionCount, seed.activityCount)
          graph.nodes[offset].sourceContexts = Self.mergedContexts(
            graph.nodes[offset].referencedSourceContexts,
            seed.contexts.filter { Self.matches(rule: rule, in: $0.body) },
            limit: 40
          )
        }
        upsertEdge(
          from: topicParent?.id ?? project.id,
          to: topic.id,
          kind: .contains,
          now: sourceDate,
          graph: &graph
        )
      }
    }

    graph.version = max(graph.version, 3)
    if graph != original {
      graph.updatedAt = max(graph.updatedAt, sourceDate)
      try save(graph)
    }
    try archivePrunedNotes(prunedNotePaths, currentGraph: graph)
    try archiveOrphanedGeneratedNotes(currentGraph: graph)
    return seeds.count
  }

  @discardableResult
  func importCodexMemoryIfAvailable() throws -> Int {
    let expectedWorkspace = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/rook", isDirectory: true)
      .standardizedFileURL
    guard config.rookWorkspaceURL.standardizedFileURL == expectedWorkspace else { return 0 }
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".codex/memories/MEMORY.md")
    guard fileManager.isReadableFile(atPath: url.path) else { return 0 }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let sourceDate = attributes[.modificationDate] as? Date ?? Date()
    return try importCatalog(markdown: String(contentsOf: url, encoding: .utf8), sourceDate: sourceDate)
  }

  func context(for query: String, index: RookLibraryIndex, now: Date) -> String {
    guard let graph = try? load() else { return "Library project graph: unavailable." }
    let projects = graph.nodes.filter { $0.kind == .project }
    guard !projects.isEmpty else {
      return "Library project graph: no project nodes yet. Explicit project names will create durable nodes."
    }
    guard let resolution = Self.resolveProject(for: query, graph: graph, now: now) else {
      let names = projects.sorted { $0.mentionCount > $1.mentionCount }.prefix(5).map {
        "[[\($0.title)]] (\($0.mentionCount) activity signal\($0.mentionCount == 1 ? "" : "s"))"
      }
      return
        "Library project graph: no safe implicit match for this request. Known projects: \(names.joined(separator: ", "))."
    }

    let path = resolution.path.map { "[[\($0.title)]]" }.joined(separator: " -> ")
    let descendants = Self.descendants(of: resolution.project.id, in: graph)
    let hierarchy = descendants.prefix(12).map { node -> String in
      let parent = graph.parents(of: node.id).first?.title ?? resolution.project.title
      let alias = node.aliases.filter { Self.normalized($0) != Self.normalized(node.title) }.prefix(4)
      let suffix = alias.isEmpty ? "" : "; includes: \(alias.joined(separator: ", "))"
      return "- [[\(parent)]] -> [[\(node.title)]]\(suffix)"
    }
    let relatedTurnIDs = Set(descendants.flatMap(\.turnIDs) + resolution.project.turnIDs)
    let related = index.entries.filter { relatedTurnIDs.contains($0.id) }.prefix(5)
    let history = related.map {
      "- \(Self.iso($0.updatedAt)) | \($0.label) | \($0.status.rawValue) | \(Self.compact($0.summary, limit: 220))"
    }

    var lines = [
      "Library project graph resolved: [[\(resolution.project.title)]] (\(resolution.confidence.rawValue) confidence; \(resolution.reason)).",
      "Resolved node path: \(path). Treat unnamed references such as 'my app' as this project unless live filesystem evidence conflicts.",
    ]
    if !resolution.project.referencedWorkspacePaths.isEmpty {
      lines.append(
        "Recorded project workspaces: "
          + resolution.project.referencedWorkspacePaths.map { "`\($0)`" }.joined(separator: ", ")
          + ". Verify the selected path live before file work."
      )
    }
    lines.append("Known project branches:")
    lines += hierarchy.isEmpty ? ["- No subnodes captured yet."] : hierarchy
    lines.append("Recent work attached to [[\(resolution.project.title)]]:")
    lines += history.isEmpty ? ["- No archived turns attached yet."] : history
    return Self.compact(lines.joined(separator: "\n"), limit: 3_400)
  }

  private func associate(
    command: String,
    summary: String,
    turnID: UUID,
    existingNodeIDs: [String],
    now: Date,
    graph: inout RookLibraryGraph
  ) -> [String] {
    let combined = [command, summary].filter { !$0.isEmpty }.joined(separator: " ")
    let explicitProject = Self.explicitProjectName(in: command)
    let project: RookLibraryNode?
    if let explicitProject {
      project = upsertProject(named: explicitProject, evidence: combined, now: now, graph: &graph)
    } else if let existingProject = existingNodeIDs.compactMap({ graph.node(id: $0) }).first(where: {
      $0.kind == .project
    }) {
      project = existingProject
    } else {
      project = Self.resolveProject(for: combined, graph: graph, now: now)?.project
    }

    var associated = Set(existingNodeIDs)
    var parentID: String?
    if let project {
      touch(nodeID: project.id, turnID: turnID, evidence: combined, now: now, graph: &graph)
      associated.insert(project.id)
      parentID = project.id
    }

    let matchedCategories = Self.categoryRules.filter { Self.matches(rule: $0, in: combined) }
    var categoryNodes: [RookLibraryNode] = []
    for rule in matchedCategories {
      let node = upsertConcept(
        rule: rule,
        kind: .category,
        parentID: project?.id,
        turnID: turnID,
        evidence: combined,
        now: now,
        graph: &graph
      )
      categoryNodes.append(node)
      associated.insert(node.id)
      if let project { upsertEdge(from: project.id, to: node.id, kind: .contains, now: now, graph: &graph) }
    }

    if let category = categoryNodes.first {
      parentID = category.id
    } else if let project {
      let existingCategories = graph.children(of: project.id).filter { $0.kind == .category }
      if existingCategories.count == 1 { parentID = existingCategories[0].id }
    }

    for rule in Self.topicRules where Self.matches(rule: rule, in: combined) {
      let node = upsertConcept(
        rule: rule,
        kind: .topic,
        parentID: parentID,
        turnID: turnID,
        evidence: combined,
        now: now,
        graph: &graph
      )
      associated.insert(node.id)
      if let parentID { upsertEdge(from: parentID, to: node.id, kind: .contains, now: now, graph: &graph) }
    }

    graph.updatedAt = max(graph.updatedAt, now)
    return associated.sorted()
  }

  private func upsertProject(
    named rawName: String,
    evidence: String,
    now: Date,
    graph: inout RookLibraryGraph
  ) -> RookLibraryNode {
    let name = Self.cleanProjectName(rawName)
    let normalizedName = Self.normalized(name)
    if let offset = graph.nodes.firstIndex(where: {
      $0.kind == .project
        && (Self.normalized($0.title) == normalizedName
          || $0.aliases.contains(where: { Self.normalized($0) == normalizedName }))
    }) {
      graph.nodes[offset].updatedAt = max(graph.nodes[offset].updatedAt, now)
      graph.nodes[offset].keywords = Self.merged(graph.nodes[offset].keywords, Self.tokens(evidence), limit: 80)
      return graph.nodes[offset]
    }

    let slug = Self.slug(name)
    let node = RookLibraryNode(
      id: "project:\(slug)",
      kind: .project,
      title: name,
      aliases: [name],
      keywords: Array(Self.tokens(evidence).prefix(80)),
      createdAt: now,
      updatedAt: now,
      notePath: "nodes/projects/\(slug)/index.md"
    )
    graph.nodes.append(node)
    return node
  }

  private func upsertConcept(
    rule: ConceptRule,
    kind: RookLibraryNodeKind,
    parentID: String?,
    turnID: UUID?,
    evidence: String,
    now: Date,
    graph: inout RookLibraryGraph
  ) -> RookLibraryNode {
    let scope = parentID ?? "root"
    let id = "\(kind.rawValue):\(scope)/\(Self.slug(rule.title))"
    if !graph.nodes.contains(where: { $0.id == id }) {
      let parentPath = parentID.flatMap { graph.node(id: $0)?.notePath }
      let notePath: String
      if let parentPath {
        let parentFolder = (parentPath as NSString).deletingLastPathComponent
        notePath =
          kind == .category
          ? "\(parentFolder)/\(Self.slug(rule.title))/index.md"
          : "\(parentFolder)/\(Self.slug(rule.title)).md"
      } else {
        notePath = "nodes/categories/\(Self.slug(rule.title)).md"
      }
      graph.nodes.append(
        RookLibraryNode(
          id: id,
          kind: kind,
          title: rule.title,
          aliases: Self.merged([rule.title], rule.aliases, limit: 20),
          keywords: Self.tokens(evidence),
          createdAt: now,
          updatedAt: now,
          notePath: notePath
        ))
    }
    touch(nodeID: id, turnID: turnID, evidence: evidence, now: now, graph: &graph)
    return graph.node(id: id)!
  }

  private func touch(
    nodeID: String,
    turnID: UUID?,
    evidence: String,
    now: Date,
    graph: inout RookLibraryGraph
  ) {
    guard let offset = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
    if let turnID, !graph.nodes[offset].turnIDs.contains(turnID) {
      graph.nodes[offset].turnIDs.append(turnID)
      graph.nodes[offset].turnIDs = Array(graph.nodes[offset].turnIDs.suffix(500))
      graph.nodes[offset].mentionCount += 1
    }
    graph.nodes[offset].keywords = Self.merged(graph.nodes[offset].keywords, Self.tokens(evidence), limit: 80)
    graph.nodes[offset].updatedAt = max(graph.nodes[offset].updatedAt, now)
  }

  private func upsertEdge(
    from sourceID: String,
    to targetID: String,
    kind: RookLibraryEdgeKind,
    now: Date,
    graph: inout RookLibraryGraph
  ) {
    let id = "\(sourceID)->\(targetID):\(kind.rawValue)"
    if let offset = graph.edges.firstIndex(where: { $0.id == id }) {
      graph.edges[offset].updatedAt = max(graph.edges[offset].updatedAt, now)
    } else {
      graph.edges.append(
        RookLibraryEdge(sourceID: sourceID, targetID: targetID, kind: kind, createdAt: now, updatedAt: now))
    }
  }

  private func pruneCatalogOnlyDescendants(projectID: String, graph: inout RookLibraryGraph) -> Set<String> {
    let descendants = Self.descendants(of: projectID, in: graph)
    let removedNodes = descendants.filter { $0.turnIDs.isEmpty }
    let removable = Set(removedNodes.map(\.id))
    guard !removable.isEmpty else { return [] }
    graph.nodes.removeAll { removable.contains($0.id) }
    graph.edges.removeAll { removable.contains($0.sourceID) || removable.contains($0.targetID) }
    return Set(removedNodes.map(\.notePath))
  }

  private func archivePrunedNotes(_ notePaths: Set<String>, currentGraph: RookLibraryGraph) throws {
    let currentPaths = Set(currentGraph.nodes.map(\.notePath))
    let stalePaths = notePaths.subtracting(currentPaths)
    guard !stalePaths.isEmpty else { return }
    let archiveRoot = config.libraryURL.appendingPathComponent(".orphaned-nodes", isDirectory: true)

    for relativePath in stalePaths.sorted() {
      let source = config.libraryURL.appendingPathComponent(relativePath).standardizedFileURL
      guard source.path.hasPrefix(config.libraryNodesURL.standardizedFileURL.path + "/"),
        fileManager.fileExists(atPath: source.path)
      else { continue }
      var destination = archiveRoot.appendingPathComponent(relativePath)
      try Self.createPrivateDirectory(destination.deletingLastPathComponent())
      if fileManager.fileExists(atPath: destination.path) {
        destination = destination.deletingPathExtension()
          .appendingPathExtension(UUID().uuidString.lowercased() + ".md")
      }
      try fileManager.moveItem(at: source, to: destination)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
  }

  private func archiveOrphanedGeneratedNotes(currentGraph: RookLibraryGraph) throws {
    let expectedPaths = Set(currentGraph.nodes.map(\.notePath))
    guard
      let enumerator = fileManager.enumerator(
        at: config.libraryNodesURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return }
    var orphaned = Set<String>()
    let libraryPrefix = config.libraryURL.standardizedFileURL.path + "/"

    for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
      let standardized = url.standardizedFileURL
      guard standardized.path.hasPrefix(libraryPrefix) else { continue }
      let relativePath = String(standardized.path.dropFirst(libraryPrefix.count))
      guard !expectedPaths.contains(relativePath),
        let data = try? Data(contentsOf: standardized, options: .mappedIfSafe),
        let prefix = String(data: data.prefix(600), encoding: .utf8),
        prefix.hasPrefix("---\nid: "), prefix.contains("\nkind: ")
      else { continue }
      orphaned.insert(relativePath)
    }
    try archivePrunedNotes(orphaned, currentGraph: currentGraph)
  }

  private func save(_ value: RookLibraryGraph) throws {
    var graph = value
    graph.nodes.sort {
      if $0.kind != $1.kind { return Self.kindRank($0.kind) < Self.kindRank($1.kind) }
      return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
    graph.edges.sort { $0.id < $1.id }
    try Self.createPrivateDirectory(config.libraryNodesURL)
    try RookConfig.writePrivate(try Self.encoder().encode(graph), to: config.libraryGraphURL)
    for node in graph.nodes { try saveNote(node, graph: graph) }
  }

  private func saveNote(_ node: RookLibraryNode, graph: RookLibraryGraph) throws {
    let url = config.libraryURL.appendingPathComponent(node.notePath)
    try Self.createPrivateDirectory(url.deletingLastPathComponent())
    let parents = graph.parents(of: node.id)
    let children = graph.children(of: node.id)
    let links = graph.edges.filter {
      $0.kind == .relatedTo && ($0.sourceID == node.id || $0.targetID == node.id)
    }.compactMap { edge -> RookLibraryNode? in
      graph.node(id: edge.sourceID == node.id ? edge.targetID : edge.sourceID)
    }
    var lines = [
      "---",
      "id: \(node.id)",
      "kind: \(node.kind.rawValue)",
      "mentions: \(node.mentionCount)",
      "updated: \(Self.iso(node.updatedAt))",
      "aliases:",
    ]
    lines += node.aliases.map { "  - \($0)" }
    lines += ["---", "", "# \(node.title)", ""]
    if !node.referencedWorkspacePaths.isEmpty {
      lines += ["## Workspaces", ""] + node.referencedWorkspacePaths.map { "- `\($0)`" } + [""]
    }
    if !parents.isEmpty {
      lines += ["## Parent", ""] + parents.map { "- \(Self.wikiLink(to: $0))" } + [""]
    }
    if !children.isEmpty {
      lines += ["## Branches", ""] + children.map { "- \(Self.wikiLink(to: $0))" } + [""]
    }
    if !links.isEmpty {
      lines += ["## Related", ""] + links.map { "- \(Self.wikiLink(to: $0))" } + [""]
    }
    if !node.referencedSourceContexts.isEmpty {
      lines += ["## Stored source context", ""]
      for context in node.referencedSourceContexts {
        lines += [
          "### \(context.title)",
          "",
          "- Source: \(context.source)",
          "- Updated: \(Self.iso(context.updatedAt))",
          "",
          context.body,
          "",
        ]
      }
    }
    lines += [
      "## Attached work",
      "",
      "\(node.mentionCount) recorded activity signal\(node.mentionCount == 1 ? "" : "s") reference this node.",
      "",
      "Attached Rook turn IDs are retained in `graph.json`; seeded projects may also use high-level Codex task-group counts. Conversation notes remain under `conversations/`.",
      "",
    ]
    try RookConfig.writePrivate(Data(lines.joined(separator: "\n").utf8), to: url)
  }

  private static func resolveProject(
    for query: String,
    graph: RookLibraryGraph,
    now: Date
  ) -> RookProjectResolution? {
    let projects = graph.nodes.filter { $0.kind == .project }
    guard !projects.isEmpty else { return nil }
    let normalizedQuery = normalized(query)
    let queryTokens = Set(tokens(query))
    let explicitReference = containsProjectReference(normalizedQuery)

    let candidates = projects.map { project -> ProjectCandidate in
      let descendants = descendants(of: project.id, in: graph)
      let aliases = [project.title] + project.aliases
      let exactAlias = aliases.contains { alias in
        let value = normalized(alias)
        return value.count > 1
          && normalizedQuery.range(
            of: #"\b"# + NSRegularExpression.escapedPattern(for: value) + #"\b"#, options: .regularExpression) != nil
      }
      let descendantPhraseMatches = descendants.filter {
        let title = normalized($0.title)
        return title.count > 2 && normalizedQuery.contains(title)
          || $0.aliases.contains(where: { normalizedQuery.contains(normalized($0)) })
      }
      let projectTerms = Set(project.keywords + tokens(project.title) + project.aliases.flatMap(tokens))
      let descendantTerms = Set(descendants.flatMap { tokens($0.title) + $0.aliases.flatMap(tokens) + $0.keywords })
      let projectOverlap = queryTokens.intersection(projectTerms).count
      let descendantOverlap = queryTokens.intersection(descendantTerms).count
      var semantic = exactAlias ? 120 : 0
      semantic += descendantPhraseMatches.reduce(0) { score, node in
        score + (node.kind == .category ? 60 : 30)
      }
      semantic += projectOverlap * 10
      semantic += descendantOverlap * 6
      let age = max(0, now.timeIntervalSince(project.updatedAt))
      let recency = age <= 7 * 86_400 ? 12 : (age <= 30 * 86_400 ? 6 : 0)
      let activity = min(24, project.mentionCount * 3)
      return ProjectCandidate(
        project: project,
        semanticScore: semantic,
        totalScore: semantic + recency + activity,
        matchedNodeIDs: descendantPhraseMatches.map(\.id)
      )
    }.sorted {
      if $0.totalScore != $1.totalScore { return $0.totalScore > $1.totalScore }
      return $0.project.updatedAt > $1.project.updatedAt
    }

    guard let top = candidates.first else { return nil }
    let second = candidates.dropFirst().first
    let explicitName = [top.project.title] + top.project.aliases
    let named = explicitName.contains { normalizedQuery.contains(normalized($0)) }
    let semanticCandidates = candidates.filter { $0.semanticScore > 0 }
    let structuredCandidates = candidates.filter { !$0.matchedNodeIDs.isEmpty }
    let onlyProject = projects.count == 1
    let dominant =
      second == nil
      || top.semanticScore >= (second?.semanticScore ?? 0) + 20
      || (top.project.mentionCount >= 3
        && top.project.mentionCount >= max(1, (second?.project.mentionCount ?? 0) * 3)
        && top.semanticScore > 0)
    let hasStructuredTopicMatch = !top.matchedNodeIDs.isEmpty

    guard
      named
        || ((explicitReference || hasStructuredTopicMatch) && top.semanticScore > 0
          && (structuredCandidates.count == 1 || semanticCandidates.count == 1 || dominant))
        || (onlyProject && explicitReference)
    else { return nil }

    let confidence: RookProjectResolution.Confidence =
      named || structuredCandidates.count == 1 || semanticCandidates.count == 1 ? .high : .medium
    let reason: String
    if named {
      reason = "project name or alias matched"
    } else if structuredCandidates.count == 1 || semanticCandidates.count == 1 {
      reason = "it is the only project matching the requested area"
    } else if onlyProject {
      reason = "it is the only project in the Library"
    } else {
      reason = "its topic match and activity clearly dominate the alternatives"
    }

    let matched = top.matchedNodeIDs.compactMap { graph.node(id: $0) }
    let path = [top.project] + Self.bestPathNodes(from: top.project.id, matched: matched, graph: graph)
    return RookProjectResolution(project: top.project, confidence: confidence, reason: reason, path: path)
  }

  private static func bestPathNodes(
    from projectID: String,
    matched: [RookLibraryNode],
    graph: RookLibraryGraph
  ) -> [RookLibraryNode] {
    guard
      let leaf = matched.sorted(by: {
        if kindRank($0.kind) != kindRank($1.kind) { return kindRank($0.kind) > kindRank($1.kind) }
        return $0.mentionCount > $1.mentionCount
      }).first
    else { return [] }
    var reverse: [RookLibraryNode] = [leaf]
    var current = leaf
    while let parent = graph.parents(of: current.id).first, parent.id != projectID {
      reverse.append(parent)
      current = parent
    }
    return reverse.reversed()
  }

  private static func descendants(of nodeID: String, in graph: RookLibraryGraph) -> [RookLibraryNode] {
    var result: [RookLibraryNode] = []
    var queue = graph.children(of: nodeID)
    var seen = Set<String>()
    while !queue.isEmpty {
      let node = queue.removeFirst()
      guard seen.insert(node.id).inserted else { continue }
      result.append(node)
      queue += graph.children(of: node.id)
    }
    return result.sorted {
      if kindRank($0.kind) != kindRank($1.kind) { return kindRank($0.kind) < kindRank($1.kind) }
      if $0.mentionCount != $1.mentionCount { return $0.mentionCount > $1.mentionCount }
      return $0.title < $1.title
    }
  }

  private static func explicitProjectName(in value: String) -> String? {
    let patterns = [
      #"(?i)\b(?:project|app|application|website|repository|repo|product)\s+(?:called|named)\s+[\"“']?([a-z0-9][a-z0-9&' -]{1,60}?)(?=[\"”']?(?:\s+(?:from|since|on|in|for|with|that|which)\b|[,.!?\n]|$))"#,
      #"\b(?:working on|work on|building|developing)\s+(?:the\s+|my\s+|this\s+|a\s+|an\s+)?([A-Z][A-Za-z0-9&'-]*(?:\s+[A-Z][A-Za-z0-9&'-]*){0,3})"#,
      #"\b([A-Z][A-Za-z0-9&'-]*(?:\s+[A-Z][A-Za-z0-9&'-]*){0,3})\s+(?:project|app|application|website|repository|repo|product)\b"#,
    ]
    for pattern in patterns {
      if let capture = firstCapture(in: value, pattern: pattern) {
        let cleaned = cleanProjectName(capture)
        if !cleaned.isEmpty, !genericProjectNames.contains(normalized(cleaned)) { return cleaned }
      }
    }
    return nil
  }

  private static func catalogSeeds(from markdown: String, sourceDate: Date) -> [CatalogSeed] {
    let marker = "# Task Group:"
    let chunks = markdown.components(separatedBy: marker).dropFirst()
    var seedsByPath: [String: CatalogSeed] = [:]

    for rawChunk in chunks {
      let chunk = marker + rawChunk
      guard
        let pathCapture = firstCapture(
          in: chunk,
          pattern: #"(?m)^applies_to:\s*cwd=([^;\n]+)"#
        )
      else { continue }
      let firstPath =
        pathCapture.components(separatedBy: " and /").first?
        .components(separatedBy: " and its ").first ?? pathCapture
      let path = firstPath.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
      guard path.hasPrefix("/"), !path.contains(".."), !path.contains("{"),
        !path.contains("/Documents/Codex/"), !path.contains("/.codex/")
      else { continue }
      let folder = URL(fileURLWithPath: path).lastPathComponent
      guard !folder.isEmpty else { continue }
      let activity = max(1, chunk.components(separatedBy: "rollout_summaries/").count - 1)
      let aliases = projectAliases(folder: folder, evidence: chunk)
      let title = aliases.first ?? displayName(folder)
      let contextLines = rawChunk.components(separatedBy: .newlines)
      let groupTitle =
        contextLines.first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Imported project context"
      let context = RookLibraryNodeContext(
        id: "codex-memory:\(slug(groupTitle))",
        source: "Codex Memory",
        title: groupTitle,
        body: contextLines.dropFirst().joined(separator: "\n")
          .trimmingCharacters(in: .whitespacesAndNewlines),
        updatedAt: sourceDate
      )

      if var existing = seedsByPath[path] {
        existing.activityCount += activity
        existing.evidence = compact(existing.evidence + "\n" + chunk, limit: 18_000)
        existing.aliases = merged(existing.aliases, aliases, limit: 20)
        existing.contexts = mergedContexts(existing.contexts, [context], limit: 60)
        seedsByPath[path] = existing
      } else {
        seedsByPath[path] = CatalogSeed(
          path: path,
          title: title,
          aliases: aliases,
          evidence: compact(chunk, limit: 18_000),
          activityCount: activity,
          contexts: [context]
        )
      }
    }
    return seedsByPath.values.sorted { $0.activityCount > $1.activityCount }
  }

  private static func projectAliases(folder: String, evidence: String) -> [String] {
    let fallback = displayName(folder)
    let normalizedFolder = normalized(folder).replacingOccurrences(of: " ", with: "")
    let expression = try? NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9]{2,30}\b"#)
    let range = NSRange(evidence.startIndex..., in: evidence)
    let matches =
      expression?.matches(in: evidence, range: range).compactMap { match -> String? in
        guard let range = Range(match.range, in: evidence) else { return nil }
        let value = String(evidence[range])
        let normalizedValue = normalized(value).replacingOccurrences(of: " ", with: "")
        guard normalizedValue.hasPrefix(normalizedFolder) || normalizedFolder.hasPrefix(normalizedValue) else {
          return nil
        }
        return value
      } ?? []
    var aliases = merged([fallback], matches, limit: 12)
    if aliases.contains(where: { normalized($0).replacingOccurrences(of: " ", with: "") == "jocklynx" }) {
      aliases = merged(aliases, ["Jock Lynx", "Jocks Links", "Jock Links"], limit: 12)
    }
    return aliases
  }

  private static func displayName(_ folder: String) -> String {
    folder.replacingOccurrences(of: "[-_]", with: " ", options: .regularExpression)
      .split(whereSeparator: \.isWhitespace)
      .map { word in
        let value = String(word)
        return value.count <= 3 ? value.uppercased() : value.prefix(1).uppercased() + value.dropFirst()
      }
      .joined(separator: " ")
  }

  private static let genericProjectNames: Set<String> = [
    "a", "an", "the", "my", "this", "social", "social media", "new", "current", "same", "web", "mobile",
  ]

  private static func cleanProjectName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    let words = trimmed.split(whereSeparator: \.isWhitespace).prefix(5).map(String.init)
    return words.joined(separator: " ")
  }

  private static func containsProjectReference(_ value: String) -> Bool {
    let phrases = [
      "my project", "the project", "this project", "my app", "the app", "this app", "my application",
      "the application", "this application", "my website", "the website", "this website", "my social media",
      "the social media", "this social media", "my repo", "the repo", "this repo",
    ]
    return phrases.contains(where: value.contains)
  }

  private static func matches(rule: ConceptRule, in value: String) -> Bool {
    let normalizedValue = normalized(value)
    return rule.aliases.contains { alias in
      let escaped = NSRegularExpression.escapedPattern(for: normalized(alias))
      return normalizedValue.range(of: #"\b"# + escaped + #"\b"#, options: .regularExpression) != nil
    }
  }

  private static func merged(_ lhs: [String], _ rhs: [String], limit: Int) -> [String] {
    var seen = Set<String>()
    return (lhs + rhs).filter { seen.insert(normalized($0)).inserted }.prefix(limit).map { $0 }
  }

  private static func mergedContexts(
    _ lhs: [RookLibraryNodeContext],
    _ rhs: [RookLibraryNodeContext],
    limit: Int
  ) -> [RookLibraryNodeContext] {
    var byID = Dictionary(uniqueKeysWithValues: lhs.map { ($0.id, $0) })
    for context in rhs {
      if let existing = byID[context.id], existing.updatedAt > context.updatedAt { continue }
      byID[context.id] = context
    }
    return Array(
      byID.values.sorted {
        if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }.prefix(limit))
  }

  private static func tokens(_ value: String) -> [String] {
    let ignored: Set<String> = [
      "a", "an", "and", "are", "as", "at", "be", "can", "could", "do", "for", "from", "i", "in", "is",
      "it", "me", "my", "of", "on", "or", "please", "rook", "that", "the", "this", "to", "was", "what",
      "with", "would", "you", "new", "work", "working", "add", "adding", "system",
    ]
    return normalized(value).split(whereSeparator: \.isWhitespace).map(String.init)
      .filter { $0.count > 1 && !ignored.contains($0) }
  }

  private static func normalized(_ value: String) -> String {
    value.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func slug(_ value: String) -> String {
    let output = normalized(value).replacingOccurrences(of: " ", with: "-")
    return output.isEmpty ? "untitled" : String(output.prefix(64))
  }

  private static func kindRank(_ kind: RookLibraryNodeKind) -> Int {
    switch kind {
    case .project: return 0
    case .category: return 1
    case .topic: return 2
    }
  }

  private static func wikiLink(to node: RookLibraryNode) -> String {
    let path = String(node.notePath.dropLast(node.notePath.hasSuffix(".md") ? 3 : 0))
    return "[[\(path)|\(node.title)]]"
  }

  private static func firstCapture(in value: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[range])
  }

  private static func compact(_ value: String, limit: Int) -> String {
    let cleaned = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count > limit else { return cleaned }
    return String(cleaned.prefix(max(1, limit - 1))) + "…"
  }

  private static func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func createPrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }
}
