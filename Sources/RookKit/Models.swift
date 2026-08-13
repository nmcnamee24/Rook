import Foundation

public struct PawnDefinition: Identifiable, Equatable, Sendable {
  public let name: String
  public let specialty: String

  public var id: String { name }

  public init(name: String, specialty: String) {
    self.name = name
    self.specialty = specialty
  }

  public static let all: [PawnDefinition] = [
    PawnDefinition(name: "Scout", specialty: "Research and source discovery"),
    PawnDefinition(name: "Forge", specialty: "Code, files, and implementation"),
    PawnDefinition(name: "Scribe", specialty: "Drafting and polished writing"),
    PawnDefinition(name: "Steward", specialty: "Calendar, Gmail, and operations"),
    PawnDefinition(name: "Auditor", specialty: "Verification, conflicts, and risk checks"),
  ]

  public static var defaultNames: [String] { all.map(\.name) }
}

public enum RookQueueLabel {
  public static func make(kind: String, title: String, explicitLabel: String? = nil) -> String {
    if let explicit = cleaned(explicitLabel), !explicit.isEmpty {
      return capped(explicit)
    }

    let cleanTitle = cleaned(title) ?? "Review action"
    let words = cleanTitle.split(whereSeparator: \.isWhitespace).map(String.init)
    let lowerKind = kind.lowercased()

    if lowerKind == "calendar_update", words.first?.lowercased() == "move" {
      let subject = words.dropFirst().prefix { word in
        !["to", "at", "on", "from"].contains(word.lowercased())
      }
      let core = subject.isEmpty ? ["event"] : Array(subject.prefix(2))
      return capped((["Move"] + core + ["time"]).joined(separator: " "))
    }

    if lowerKind == "calendar_update" {
      return prefixed("Update", title: cleanTitle)
    }
    if lowerKind == "calendar_create" {
      return prefixed("Add", title: cleanTitle)
    }
    if lowerKind == "gmail_draft" {
      if cleanTitle.lowercased().contains("meeting notes") {
        return "Draft meeting notes"
      }
      return prefixed("Draft", title: cleanTitle)
    }
    if lowerKind.contains("email") || lowerKind.contains("gmail") {
      return prefixed("Send", title: cleanTitle)
    }
    if lowerKind.contains("delete") {
      return prefixed("Review", title: cleanTitle)
    }
    return capped(cleanTitle)
  }

  private static func prefixed(_ action: String, title: String) -> String {
    let words = title.split(whereSeparator: \.isWhitespace).map(String.init)
    if words.first?.lowercased() == action.lowercased() {
      return capped(title)
    }
    return capped(([action] + words).joined(separator: " "))
  }

  private static func capped(_ value: String) -> String {
    let words = value.split(whereSeparator: \.isWhitespace).prefix(4)
    let result = words.joined(separator: " ")
    guard let first = result.first else { return "Review action" }
    return first.uppercased() + result.dropFirst()
  }

  private static func cleaned(_ value: String?) -> String? {
    value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }
}

public struct PawnPlan: Codable, Equatable, Sendable {
  public let pawn: String
  public let task: String
  public let id: String?

  public init(pawn: String, task: String, id: String? = nil) {
    self.pawn = pawn
    self.task = task
    self.id = id
  }

  public var instanceLabel: String { Self.instanceLabel(role: pawn, id: id) }

  static func instanceLabel(role: String, id: String?) -> String {
    guard let id,
      let suffix = id.split(separator: "_").last,
      let number = Int(suffix)
    else { return role }
    return "\(role) \(number)"
  }
}

public struct PawnReport: Codable, Equatable, Sendable {
  public let pawn: String
  public let task: String
  public let status: String
  public let id: String?
  public let result: String?
  public let evidence: [String]?

  public init(
    pawn: String,
    task: String,
    status: String,
    id: String? = nil,
    result: String? = nil,
    evidence: [String]? = nil
  ) {
    self.pawn = pawn
    self.task = task
    self.status = status
    self.id = id
    self.result = result
    self.evidence = evidence
  }

  public var instanceLabel: String { PawnPlan.instanceLabel(role: pawn, id: id) }
  public var reportedResult: String? {
    guard let value = result?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    return value
  }
  public var reportedEvidence: [String] {
    (evidence ?? []).compactMap {
      let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : value
    }
  }
}

public enum RookCanvasKind: String, Codable, CaseIterable, Sendable {
  case weather
  case calendar
  case spotify
  case image
  case code
  case diagram
  case list
  case computer
}

public enum RookCanvasSymbol: String, Codable, CaseIterable, Sendable {
  case sun
  case partlyCloudy = "partly_cloudy"
  case cloudy
  case rain
  case storm
  case snow
  case wind
  case fog
  case calendar
  case clock
  case code
  case image
  case diagram
  case computer
  case music
  case info
  case warning
}

public struct RookCanvasItem: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let detail: String
  public let value: String
  public let symbol: RookCanvasSymbol
  public let start: String
  public let end: String

  public init(
    id: String,
    label: String,
    detail: String = "",
    value: String = "",
    symbol: RookCanvasSymbol = .info,
    start: String = "",
    end: String = ""
  ) {
    self.id = id
    self.label = label
    self.detail = detail
    self.value = value
    self.symbol = symbol
    self.start = start
    self.end = end
  }
}

public struct RookCanvasBlock: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let kind: RookCanvasKind
  public let title: String
  public let subtitle: String
  public let asOf: String
  public let items: [RookCanvasItem]
  public let imageURL: String
  /// A private Rook-managed image reference attached by the native bridge.
  /// This is intentionally absent from the model output schema: models may
  /// request an image block, but only trusted native code can mint an asset ID.
  public let imageAssetID: String?
  public let caption: String
  public let body: String
  public let secondaryBody: String
  public let language: String
  public let sourceLabel: String
  public let sourceURL: String

  enum CodingKeys: String, CodingKey {
    case id
    case kind
    case title
    case subtitle
    case asOf = "as_of"
    case items
    case imageURL = "image_url"
    case imageAssetID = "image_asset_id"
    case caption
    case body
    case secondaryBody = "secondary_body"
    case language
    case sourceLabel = "source_label"
    case sourceURL = "source_url"
  }

  public init(
    id: String,
    kind: RookCanvasKind,
    title: String,
    subtitle: String = "",
    asOf: String = "",
    items: [RookCanvasItem] = [],
    imageURL: String = "",
    imageAssetID: String? = nil,
    caption: String = "",
    body: String = "",
    secondaryBody: String = "",
    language: String = "",
    sourceLabel: String = "",
    sourceURL: String = ""
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.asOf = asOf
    self.items = items
    self.imageURL = imageURL
    self.imageAssetID = imageAssetID
    self.caption = caption
    self.body = body
    self.secondaryBody = secondaryBody
    self.language = language
    self.sourceLabel = sourceLabel
    self.sourceURL = sourceURL
  }

  public static let outputSchema = #"""
    {
      "type": "object",
      "properties": {
        "id": { "type": "string", "pattern": "^[a-z][a-z0-9_]{1,39}$" },
        "kind": { "type": "string", "enum": ["weather", "calendar", "spotify", "image", "code", "diagram", "list", "computer"] },
        "title": { "type": "string", "minLength": 1, "maxLength": 120 },
        "subtitle": { "type": "string", "maxLength": 200 },
        "as_of": { "type": "string", "maxLength": 100 },
        "items": {
          "type": "array",
          "maxItems": 12,
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "string", "pattern": "^[a-z][a-z0-9_]{1,39}$" },
              "label": { "type": "string", "minLength": 1, "maxLength": 160 },
              "detail": { "type": "string", "maxLength": 240 },
              "value": { "type": "string", "maxLength": 120 },
              "symbol": {
                "type": "string",
                "enum": ["sun", "partly_cloudy", "cloudy", "rain", "storm", "snow", "wind", "fog", "calendar", "clock", "code", "image", "diagram", "computer", "music", "info", "warning"]
              },
              "start": { "type": "string", "maxLength": 100 },
              "end": { "type": "string", "maxLength": 100 }
            },
            "required": ["id", "label", "detail", "value", "symbol", "start", "end"],
            "additionalProperties": false
          }
        },
        "image_url": { "type": "string", "maxLength": 2000 },
        "caption": { "type": "string", "maxLength": 300 },
        "body": { "type": "string", "maxLength": 12000 },
        "secondary_body": { "type": "string", "maxLength": 12000 },
        "language": { "type": "string", "maxLength": 40 },
        "source_label": { "type": "string", "maxLength": 100 },
        "source_url": { "type": "string", "maxLength": 2000 }
      },
      "required": [
        "id", "kind", "title", "subtitle", "as_of", "items", "image_url", "caption",
        "body", "secondary_body", "language", "source_label", "source_url"
      ],
      "additionalProperties": false
    }
    """#
}

public struct QuickRookResponse: Codable, Equatable, Sendable {
  public let displayText: String
  public let spokenText: String
  public let route: String
  public let intent: String
  public let pawns: [PawnPlan]
  public let canvas: [RookCanvasBlock]

  enum CodingKeys: String, CodingKey {
    case displayText = "display_text"
    case spokenText = "spoken_text"
    case route
    case intent
    case pawns
    case canvas
  }

  public init(
    displayText: String,
    spokenText: String,
    route: String,
    intent: String,
    pawns: [PawnPlan],
    canvas: [RookCanvasBlock] = []
  ) {
    self.displayText = displayText
    self.spokenText = spokenText
    self.route = route
    self.intent = intent
    self.pawns = pawns
    self.canvas = canvas
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    displayText = try container.decode(String.self, forKey: .displayText)
    spokenText = try container.decode(String.self, forKey: .spokenText)
    route = try container.decode(String.self, forKey: .route)
    intent = try container.decode(String.self, forKey: .intent)
    pawns = try container.decode([PawnPlan].self, forKey: .pawns)
    canvas = try container.decodeIfPresent([RookCanvasBlock].self, forKey: .canvas) ?? []
  }

  public var needsDeliberation: Bool { route == "deliberate" }

  public var immediateResponse: RookResponse {
    RookResponse(
      displayText: displayText,
      spokenText: spokenText,
      intent: intent,
      requiresApproval: false,
      queueItemIDs: [],
      pawns: pawns.map { PawnReport(pawn: $0.pawn, task: $0.task, status: "working", id: $0.id) },
      canvas: canvas
    )
  }

  public static let outputSchema = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "properties": {
        "display_text": {
          "type": "string",
          "minLength": 1,
          "maxLength": 1400
        },
        "spoken_text": {
          "type": "string",
          "minLength": 1,
          "maxLength": 280,
          "description": "One or two short, non-sensitive sentences for Rook to say immediately."
        },
        "route": {
          "type": "string",
          "enum": ["answer_now", "deliberate"]
        },
        "intent": {
          "type": "string",
          "enum": ["answer", "brief", "plan", "draft", "queue", "approval", "status", "error"]
        },
        "pawns": {
          "type": "array",
          "maxItems": 10,
          "items": {
            "type": "object",
            "properties": {
              "id": {
                "type": "string",
                "pattern": "^[a-z][a-z0-9_]{1,39}$"
              },
              "pawn": {
                "type": "string",
                "enum": ["Scout", "Forge", "Scribe", "Steward", "Auditor"]
              },
              "task": {
                "type": "string",
                "minLength": 1,
                "maxLength": 160
              }
            },
            "required": ["id", "pawn", "task"],
            "additionalProperties": false
          }
        },
        "canvas": {
          "type": "array",
          "maxItems": 3,
          "items": \#(RookCanvasBlock.outputSchema)
        }
      },
      "required": ["display_text", "spoken_text", "route", "intent", "pawns", "canvas"],
      "additionalProperties": false
    }
    """#
}

public struct RookResponse: Codable, Equatable, Sendable {
  public let displayText: String
  public let spokenText: String
  public let intent: String
  public let requiresApproval: Bool
  public let queueItemIDs: [String]
  public let pawns: [PawnReport]
  public let canvas: [RookCanvasBlock]

  enum CodingKeys: String, CodingKey {
    case displayText = "display_text"
    case spokenText = "spoken_text"
    case intent
    case requiresApproval = "requires_approval"
    case queueItemIDs = "queue_item_ids"
    case pawns
    case canvas
  }

  public init(
    displayText: String,
    spokenText: String,
    intent: String,
    requiresApproval: Bool,
    queueItemIDs: [String],
    pawns: [PawnReport],
    canvas: [RookCanvasBlock] = []
  ) {
    self.displayText = displayText
    self.spokenText = spokenText
    self.intent = intent
    self.requiresApproval = requiresApproval
    self.queueItemIDs = queueItemIDs
    self.pawns = pawns
    self.canvas = canvas
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    displayText = try container.decode(String.self, forKey: .displayText)
    spokenText = try container.decode(String.self, forKey: .spokenText)
    intent = try container.decode(String.self, forKey: .intent)
    requiresApproval = try container.decode(Bool.self, forKey: .requiresApproval)
    queueItemIDs = try container.decode([String].self, forKey: .queueItemIDs)
    pawns = try container.decode([PawnReport].self, forKey: .pawns)
    canvas = try container.decodeIfPresent([RookCanvasBlock].self, forKey: .canvas) ?? []
  }

  public static let outputSchema = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "properties": {
        "display_text": {
          "type": "string",
          "minLength": 1,
          "maxLength": 6000
        },
        "spoken_text": {
          "type": "string",
          "minLength": 1,
          "maxLength": 420,
          "description": "At most two short, non-sensitive sentences suitable for speaking aloud."
        },
        "intent": {
          "type": "string",
          "enum": ["answer", "brief", "plan", "draft", "queue", "approval", "status", "error"]
        },
        "requires_approval": {
          "type": "boolean"
        },
        "queue_item_ids": {
          "type": "array",
          "items": {
            "type": "string",
            "pattern": "^RQ-[0-9]{4}$"
          },
          "maxItems": 10
        },
        "pawns": {
          "type": "array",
          "maxItems": 10,
          "items": {
            "type": "object",
            "properties": {
              "id": {
                "type": "string",
                "pattern": "^[a-z][a-z0-9_]{1,39}$"
              },
              "pawn": {
                "type": "string",
                "enum": ["Scout", "Forge", "Scribe", "Steward", "Auditor"]
              },
              "task": {
                "type": "string",
                "maxLength": 240
              },
              "status": {
                "type": "string",
                "enum": ["completed", "not_needed", "blocked"]
              },
              "result": {
                "type": "string",
                "minLength": 1,
                "maxLength": 1800,
                "description": "A concise audit summary of what this pawn actually found, produced, checked, or why it was blocked. Never include hidden reasoning or raw pawn messages."
              },
              "evidence": {
                "type": "array",
                "maxItems": 8,
                "items": {
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 360
                }
              }
            },
            "required": ["id", "pawn", "task", "status", "result", "evidence"],
            "additionalProperties": false
          }
        },
        "canvas": {
          "type": "array",
          "maxItems": 3,
          "items": \#(RookCanvasBlock.outputSchema)
        }
      },
      "required": [
        "display_text",
        "spoken_text",
        "intent",
        "requires_approval",
        "queue_item_ids",
        "pawns",
        "canvas"
      ],
      "additionalProperties": false
    }
    """#
}

public struct DoctorResult: Codable {
  public let ok: Bool
  public let codexPath: String
  public let codexExecutable: Bool
  public let authentication: String
  public let queueHealthy: Bool
  public let stateDirectory: String
  public let notes: [String]

  enum CodingKeys: String, CodingKey {
    case ok
    case codexPath = "codex_path"
    case codexExecutable = "codex_executable"
    case authentication
    case queueHealthy = "queue_healthy"
    case stateDirectory = "state_directory"
    case notes
  }
}
