import Foundation

public enum RookCodingTaskStatus: String, Codable, Sendable {
  case queued
  case working
  case completed
  case blocked
  case interrupted
}

public struct RookCodingTaskRecord: Codable, Equatable, Sendable {
  public let requestID: UUID
  public var threadID: String?
  public let command: String
  public let workspacePath: String
  public var status: RookCodingTaskStatus
  public let createdAt: Date
  public var updatedAt: Date
  public var finalSummary: String?
  public var failureReason: String?

  public init(
    requestID: UUID,
    threadID: String? = nil,
    command: String,
    workspacePath: String,
    status: RookCodingTaskStatus = .queued,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    finalSummary: String? = nil,
    failureReason: String? = nil
  ) {
    self.requestID = requestID
    self.threadID = threadID
    self.command = command
    self.workspacePath = workspacePath
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.finalSummary = finalSummary
    self.failureReason = failureReason
  }
}

public final class RookCodingTaskStore: @unchecked Sendable {
  public let directoryURL: URL

  private let lock = NSLock()
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(directoryURL: URL) throws {
    self.directoryURL = directoryURL
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directoryURL.path
    )
  }

  @discardableResult
  public func begin(
    requestID: UUID,
    command: String,
    workspacePath: String,
    now: Date = Date()
  ) throws -> RookCodingTaskRecord {
    try withLock {
      if let existing = try loadUnlocked(requestID: requestID) { return existing }
      let record = RookCodingTaskRecord(
        requestID: requestID,
        command: command,
        workspacePath: workspacePath,
        createdAt: now,
        updatedAt: now
      )
      try saveUnlocked(record)
      return record
    }
  }

  @discardableResult
  public func markStarted(
    requestID: UUID,
    threadID: String,
    now: Date = Date()
  ) throws -> RookCodingTaskRecord {
    try update(requestID: requestID, now: now) { record in
      record.threadID = threadID
      record.status = .working
      record.failureReason = nil
    }
  }

  @discardableResult
  public func complete(
    requestID: UUID,
    summary: String,
    now: Date = Date()
  ) throws -> RookCodingTaskRecord {
    try update(requestID: requestID, now: now) { record in
      record.status = .completed
      record.finalSummary = Self.compact(summary, limit: 2_000)
      record.failureReason = nil
    }
  }

  @discardableResult
  public func fail(
    requestID: UUID,
    reason: String,
    interrupted: Bool = false,
    now: Date = Date()
  ) throws -> RookCodingTaskRecord {
    try update(requestID: requestID, now: now) { record in
      record.status = interrupted ? .interrupted : .blocked
      record.failureReason = Self.compact(reason, limit: 800)
    }
  }

  public func load(requestID: UUID) throws -> RookCodingTaskRecord? {
    try withLock { try loadUnlocked(requestID: requestID) }
  }

  public func recoverInterrupted(
    reason: String = "Rook stopped before the Codex task finished.",
    now: Date = Date()
  ) throws {
    try withLock {
      let files = try FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
      for file in files where file.pathExtension == "json" {
        guard var record = try? decoder.decode(RookCodingTaskRecord.self, from: Data(contentsOf: file)),
          record.status == .queued || record.status == .working
        else { continue }
        record.status = .interrupted
        record.updatedAt = now
        record.failureReason = Self.compact(reason, limit: 800)
        try saveUnlocked(record)
      }
    }
  }

  private func update(
    requestID: UUID,
    now: Date,
    mutate: (inout RookCodingTaskRecord) -> Void
  ) throws -> RookCodingTaskRecord {
    try withLock {
      guard var record = try loadUnlocked(requestID: requestID) else {
        throw RookCodingTaskError.recordMissing
      }
      mutate(&record)
      record.updatedAt = now
      try saveUnlocked(record)
      return record
    }
  }

  private func loadUnlocked(requestID: UUID) throws -> RookCodingTaskRecord? {
    let url = recordURL(requestID: requestID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try decoder.decode(RookCodingTaskRecord.self, from: Data(contentsOf: url))
  }

  private func saveUnlocked(_ record: RookCodingTaskRecord) throws {
    try RookConfig.writePrivate(try encoder.encode(record), to: recordURL(requestID: record.requestID))
  }

  private func recordURL(requestID: UUID) -> URL {
    directoryURL.appendingPathComponent("\(requestID.uuidString.lowercased()).json")
  }

  private func withLock<T>(_ body: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private static func compact(_ value: String, limit: Int) -> String {
    let cleaned =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
    return String(cleaned.prefix(limit))
  }
}

public enum RookCodingTaskProgressStage: String, Codable, Sendable {
  case starting
  case planning
  case working
  case editing
  case verifying
  case completed
}

public struct RookCodingTaskProgress: Equatable, Sendable {
  public let stage: RookCodingTaskProgressStage
  public let detail: String
  public let threadID: String?

  public init(stage: RookCodingTaskProgressStage, detail: String, threadID: String? = nil) {
    self.stage = stage
    self.detail = detail
    self.threadID = threadID
  }
}

public enum RookCodingTaskEventMapper {
  public static func progress(method: String?, itemType: String? = nil) -> RookCodingTaskProgress? {
    switch method {
    case "turn/plan/updated":
      return RookCodingTaskProgress(stage: .planning, detail: "Codex prepared its implementation plan.")
    case "item/started" where itemType == "fileChange":
      return RookCodingTaskProgress(stage: .editing, detail: "Codex is applying a scoped code change.")
    case "item/started" where itemType == "commandExecution":
      return RookCodingTaskProgress(stage: .working, detail: "Codex is working in the verified checkout.")
    case "item/completed" where itemType == "commandExecution":
      return RookCodingTaskProgress(stage: .verifying, detail: "Codex completed a repository check.")
    case "turn/completed":
      return RookCodingTaskProgress(stage: .completed, detail: "The Codex task finished.")
    default:
      return nil
    }
  }
}

public struct RookCodingTaskResult: Codable, Equatable, Sendable {
  public let threadID: String
  public let finalText: String
  public let workspacePath: String

  public init(threadID: String, finalText: String, workspacePath: String) {
    self.threadID = threadID
    self.finalText = finalText
    self.workspacePath = workspacePath
  }
}

public enum RookCodingTaskError: LocalizedError {
  case recordMissing
  case workspaceMissing
  case runtimeMissing(String)
  case serverUnavailable(String)
  case invalidResponse(String)

  public var errorDescription: String? {
    switch self {
    case .recordMissing:
      return "The private Codex task record is missing"
    case .workspaceMissing:
      return "Rook needs one verified project checkout before it can start a Codex task"
    case .runtimeMissing(let path):
      return "Codex runtime is not executable at \(path)"
    case .serverUnavailable(let detail):
      return "Codex task server failed: \(detail)"
    case .invalidResponse(let detail):
      return "Codex task returned an invalid response: \(detail)"
    }
  }
}

/// Launches one durable, non-ephemeral Codex task for coding work. Central Rook
/// selects this owner; this client does not classify requests. It deliberately
/// omits Rook's model and output-schema overrides so the task inherits the
/// user's normal full Codex configuration in the verified checkout.
public final class RookCodingTaskClient: @unchecked Sendable {
  private typealias JSON = [String: Any]

  private final class MessageStream: @unchecked Sendable {
    private let condition = NSCondition()
    private var messages: [JSON] = []
    private var closed = false

    init(handle: FileHandle) {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        var buffer = Data()
        while true {
          let data = handle.availableData
          guard !data.isEmpty else { break }
          buffer.append(data)
          while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
              let message = try? JSONSerialization.jsonObject(with: Data(line)) as? JSON
            else { continue }
            self?.enqueue(message)
          }
        }
        self?.finish()
      }
    }

    func next(until deadline: Date) throws -> JSON {
      condition.lock()
      defer { condition.unlock() }
      while messages.isEmpty, !closed {
        guard condition.wait(until: deadline) else {
          throw RookCodingTaskError.serverUnavailable("task timed out")
        }
      }
      guard !messages.isEmpty else {
        throw RookCodingTaskError.serverUnavailable("response stream closed")
      }
      return messages.removeFirst()
    }

    private func enqueue(_ message: JSON) {
      condition.lock()
      messages.append(message)
      condition.signal()
      condition.unlock()
    }

    private func finish() {
      condition.lock()
      closed = true
      condition.broadcast()
      condition.unlock()
    }
  }

  private let config: RookConfig
  private let store: RookCodingTaskStore
  private let timeout: TimeInterval
  private var nextMessageID = 1

  public init(
    config: RookConfig,
    store: RookCodingTaskStore,
    timeout: TimeInterval = 60 * 60
  ) {
    self.config = config
    self.store = store
    self.timeout = timeout
  }

  public func run(
    requestID: UUID,
    command: String,
    contextSnapshot: String,
    workspacePath: String,
    onProgress: @escaping (RookCodingTaskProgress) -> Void
  ) throws -> RookCodingTaskResult {
    let workspaceURL = try validatedWorkspaceURL(workspacePath)
    _ = try store.begin(
      requestID: requestID,
      command: command,
      workspacePath: workspaceURL.path
    )
    do {
      return try execute(
        requestID: requestID,
        command: command,
        contextSnapshot: contextSnapshot,
        workspaceURL: workspaceURL,
        onProgress: onProgress
      )
    } catch {
      _ = try? store.fail(requestID: requestID, reason: error.localizedDescription)
      throw error
    }
  }

  private func execute(
    requestID: UUID,
    command: String,
    contextSnapshot: String,
    workspaceURL: URL,
    onProgress: @escaping (RookCodingTaskProgress) -> Void
  ) throws -> RookCodingTaskResult {
    guard FileManager.default.isExecutableFile(atPath: config.codexPath) else {
      throw RookCodingTaskError.runtimeMissing(config.codexPath)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: config.codexPath)
    process.arguments = [
      "app-server", "--stdio",
      "-c", "approval_policy=\"never\"",
      "-c", "sandbox_mode=\"workspace-write\"",
      "-c", "features.multi_agent=true",
      "-c", "features.code_mode_host=true",
    ]
    process.currentDirectoryURL = workspaceURL

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    let logHandle = try openLog(at: config.taskLogURL(requestID: requestID), workspaceURL: workspaceURL)
    process.standardError = logHandle

    do {
      try process.run()
    } catch {
      try? logHandle.close()
      throw error
    }

    let stream = MessageStream(handle: outputPipe.fileHandleForReading)
    let deadline = Date().addingTimeInterval(timeout)
    var finalText: String?

    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      try? inputPipe.fileHandleForWriting.close()
      try? outputPipe.fileHandleForReading.close()
      try? logHandle.close()
    }

    onProgress(RookCodingTaskProgress(stage: .starting, detail: "Starting a full Codex task."))
    let initializeID = try sendRequest(
      method: "initialize",
      params: [
        "clientInfo": [
          "name": "rook-coding-handoff",
          "title": "Rook Coding Handoff",
          "version": "1",
        ],
        "capabilities": ["experimentalApi": true],
      ],
      to: inputPipe.fileHandleForWriting
    )
    _ = try waitForResponse(
      id: initializeID,
      stream: stream,
      inputHandle: inputPipe.fileHandleForWriting,
      deadline: deadline,
      finalText: &finalText,
      onProgress: onProgress
    )

    let threadRequestID = try sendRequest(
      method: "thread/start",
      params: [
        "cwd": workspaceURL.path,
        "approvalPolicy": "never",
        "sandbox": "workspace-write",
        "ephemeral": false,
        "serviceName": "rook-coding-handoff",
        "config": ["features": ["multi_agent": true, "code_mode_host": true]],
      ],
      to: inputPipe.fileHandleForWriting
    )
    let threadResponse = try waitForResponse(
      id: threadRequestID,
      stream: stream,
      inputHandle: inputPipe.fileHandleForWriting,
      deadline: deadline,
      finalText: &finalText,
      onProgress: onProgress
    )
    guard let result = threadResponse["result"] as? JSON,
      let thread = result["thread"] as? JSON,
      let threadID = thread["id"] as? String,
      !threadID.isEmpty
    else {
      throw RookCodingTaskError.invalidResponse("thread/start did not return an id")
    }
    _ = try store.markStarted(requestID: requestID, threadID: threadID)
    onProgress(
      RookCodingTaskProgress(
        stage: .starting,
        detail: "Codex task created in \(workspaceURL.lastPathComponent).",
        threadID: threadID
      )
    )

    let titleRequestID = try sendRequest(
      method: "thread/name/set",
      params: [
        "threadId": threadID,
        "name": "Rook · \(workspaceURL.lastPathComponent) · coding task",
      ],
      to: inputPipe.fileHandleForWriting
    )
    _ = try waitForResponse(
      id: titleRequestID,
      stream: stream,
      inputHandle: inputPipe.fileHandleForWriting,
      deadline: deadline,
      finalText: &finalText,
      onProgress: onProgress
    )

    let turnRequestID = try sendRequest(
      method: "turn/start",
      params: [
        "threadId": threadID,
        "clientUserMessageId": requestID.uuidString.lowercased(),
        "input": [
          [
            "type": "text",
            "text": codingPrompt(command: command, contextSnapshot: contextSnapshot),
            "text_elements": [],
          ]
        ],
        "cwd": workspaceURL.path,
        "approvalPolicy": "never",
      ],
      to: inputPipe.fileHandleForWriting
    )
    _ = try waitForResponse(
      id: turnRequestID,
      stream: stream,
      inputHandle: inputPipe.fileHandleForWriting,
      deadline: deadline,
      finalText: &finalText,
      onProgress: onProgress
    )

    while true {
      let message = try stream.next(until: deadline)
      try handleServerRequest(message, inputHandle: inputPipe.fileHandleForWriting)
      observe(message, finalText: &finalText, onProgress: onProgress)
      guard message["method"] as? String == "turn/completed" else { continue }
      guard let params = message["params"] as? JSON,
        let turn = params["turn"] as? JSON,
        turn["status"] as? String == "completed"
      else {
        let detail =
          (((message["params"] as? JSON)?["turn"] as? JSON)?["error"] as? JSON)?["message"]
          as? String
        throw RookCodingTaskError.serverUnavailable(detail ?? "turn failed")
      }
      if finalText == nil { finalText = completedText(from: turn) }
      break
    }

    guard let finalText = finalText?.trimmingCharacters(in: .whitespacesAndNewlines), !finalText.isEmpty else {
      throw RookCodingTaskError.invalidResponse("completed turn had no final answer")
    }
    _ = try store.complete(requestID: requestID, summary: finalText)
    return RookCodingTaskResult(
      threadID: threadID,
      finalText: finalText,
      workspacePath: workspaceURL.path
    )
  }

  private func waitForResponse(
    id: Int,
    stream: MessageStream,
    inputHandle: FileHandle,
    deadline: Date,
    finalText: inout String?,
    onProgress: (RookCodingTaskProgress) -> Void
  ) throws -> JSON {
    while true {
      let message = try stream.next(until: deadline)
      try handleServerRequest(message, inputHandle: inputHandle)
      observe(message, finalText: &finalText, onProgress: onProgress)
      guard message["method"] == nil, numericID(message["id"]) == id else { continue }
      if let error = message["error"] as? JSON {
        throw RookCodingTaskError.serverUnavailable(error["message"] as? String ?? "request failed")
      }
      return message
    }
  }

  private func handleServerRequest(_ message: JSON, inputHandle: FileHandle) throws {
    guard message["method"] != nil, message["id"] != nil else { return }
    try send(
      [
        "id": message["id"]!,
        "error": [
          "code": -32601,
          "message": "Rook coding tasks cannot grant new authority; return a clear blocked result instead.",
        ],
      ],
      to: inputHandle
    )
  }

  private func observe(
    _ message: JSON,
    finalText: inout String?,
    onProgress: (RookCodingTaskProgress) -> Void
  ) {
    let method = message["method"] as? String
    let params = message["params"] as? JSON
    let item = params?["item"] as? JSON
    if let progress = RookCodingTaskEventMapper.progress(
      method: method,
      itemType: item?["type"] as? String
    ) {
      onProgress(progress)
    }
    guard method == "item/completed",
      item?["type"] as? String == "agentMessage",
      item?["phase"] as? String == "final_answer",
      let text = item?["text"] as? String,
      !text.isEmpty
    else { return }
    finalText = text
  }

  private func completedText(from turn: JSON) -> String? {
    guard let items = turn["items"] as? [JSON] else { return nil }
    return items.reversed().first(where: {
      $0["type"] as? String == "agentMessage" && $0["phase"] as? String == "final_answer"
    })?["text"] as? String
  }

  private func codingPrompt(command: String, contextSnapshot: String) -> String {
    """
    You are the full Codex coding task launched by Rook. Rook is the voice and context front door; you own the coding work completely.

    User request:
    \(command)

    Bounded project context from Rook's private Library:
    \(contextSnapshot.isEmpty ? "No archived context was supplied. Inspect the live checkout." : contextSnapshot)

    Work directly in the verified checkout. Inspect the live repository first, preserve unrelated changes, implement the complete requested change, and verify it in proportion to risk. Use the normal Codex tools, skills, model defaults, and repository instructions available in this task. Do not delegate the coding work back to Rook or create a parallel Rook-specific implementation path. Do not send messages, publish, deploy, purchase, or make unrelated external changes. Return a concise final result with the files changed, checks run, and any genuine remaining blocker.
    """
  }

  private func validatedWorkspaceURL(_ value: String) throws -> URL {
    let candidate = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    var isDirectory: ObjCBool = false
    guard candidate.path.hasPrefix(home + "/"),
      FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw RookCodingTaskError.workspaceMissing }
    return candidate
  }

  private func sendRequest(method: String, params: JSON, to handle: FileHandle) throws -> Int {
    let id = nextMessageID
    nextMessageID += 1
    try send(["id": id, "method": method, "params": params], to: handle)
    return id
  }

  private func send(_ message: JSON, to handle: FileHandle) throws {
    var data = try JSONSerialization.data(withJSONObject: message)
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }

  private func numericID(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
  }

  private func openLog(at url: URL, workspaceURL: URL) throws -> FileHandle {
    if !FileManager.default.fileExists(atPath: url.path) {
      _ = FileManager.default.createFile(
        atPath: url.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(
      contentsOf: Data(
        "\n[\(ISO8601DateFormatter().string(from: Date()))] CODEX TASK · \(workspaceURL.path)\n".utf8
      )
    )
    return handle
  }
}
