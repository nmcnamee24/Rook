import Foundation

struct RookOperatorResult: Sendable {
  let responseText: String
  let generatedImageAssetIDs: [String]
}

enum RookComputerUseAutoApproval {
  typealias JSON = [String: Any]

  struct Decision: Equatable {
    let scopeLabel: String
    let persistAlways: Bool
  }

  static func decision(for message: JSON) -> Decision? {
    guard message["method"] as? String == "mcpServer/elicitation/request",
      let params = message["params"] as? JSON,
      params["mode"] as? String == "form",
      let metadata = params["_meta"] as? JSON,
      metadata["codex_approval_kind"] as? String == "mcp_tool_call",
      metadata["connector_id"] as? String == "computer-use"
    else { return nil }

    let toolParameters = metadata["tool_params"] as? JSON
    let app = (toolParameters?["app"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let persistence = metadata["persist"]
    let persistAlways =
      persistence as? String == "always"
      || (persistence as? [String])?.contains("always") == true
    return Decision(
      scopeLabel: (app?.isEmpty == false ? app : nil) ?? "Computer Use",
      persistAlways: persistAlways
    )
  }

  static func response(for decision: Decision) -> JSON {
    var result: JSON = [
      "action": "accept",
      "content": JSON(),
    ]
    result["_meta"] = decision.persistAlways ? ["persist": "always"] : NSNull()
    return result
  }
}

/// Runs one independent deep Rook turn over Codex app-server.
/// Computer Use app-access handshakes are accepted automatically; every other
/// server-to-client request remains unsupported so this cannot become a broad
/// approval bypass for shell, file, connector, or permission escalation.
final class RookOperatorClient: @unchecked Sendable {
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
          throw RookStreamingError.serverUnavailable("Computer Operator timed out")
        }
      }
      guard !messages.isEmpty else {
        throw RookStreamingError.serverUnavailable("Computer Operator closed its response stream")
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
  private let timeout: TimeInterval
  private var nextMessageID = 1

  init(config: RookConfig, timeout: TimeInterval = 10 * 60) {
    self.config = config
    self.timeout = timeout
  }

  func run(
    prompt: String,
    outputSchema: String,
    model: String,
    reasoningEffort: String,
    sandbox: String,
    workingDirectoryURL: URL,
    inputImageURLs: [URL],
    appConfigOverrides: [String],
    logURL: URL
  ) throws -> RookOperatorResult {
    guard FileManager.default.isExecutableFile(atPath: config.codexPath) else {
      throw RookStreamingError.runtimeMissing(config.codexPath)
    }
    guard let schemaData = outputSchema.data(using: .utf8),
      let schema = try JSONSerialization.jsonObject(with: schemaData) as? JSON
    else {
      throw RookStreamingError.invalidResponse("Computer Operator output schema is invalid")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: config.codexPath)
    var arguments = [
      "app-server", "--stdio",
      "-c", "model=\"\(model)\"",
      "-c", "model_reasoning_effort=\"\(reasoningEffort)\"",
      "-c", "approval_policy=\"on-request\"",
      "-c", "sandbox_mode=\"\(sandbox)\"",
      "-c", "features.multi_agent=true",
      "-c", "features.code_mode_host=true",
    ]
    for override in appConfigOverrides { arguments += ["-c", override] }
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectoryURL

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    let logHandle = try openLog(at: logURL, workingDirectoryURL: workingDirectoryURL)
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
    var generatedImageEvents: [String] = []

    defer {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      try? inputPipe.fileHandleForWriting.close()
      try? outputPipe.fileHandleForReading.close()
      try? logHandle.close()
    }

    let initializeID = try sendRequest(
      method: "initialize",
      params: [
        "clientInfo": [
          "name": "rook-computer-operator",
          "title": "Rook Computer Operator",
          "version": "2.9",
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
      generatedImageEvents: &generatedImageEvents,
      logHandle: logHandle
    )

    var workspaceRoots = [workingDirectoryURL.path]
    if workingDirectoryURL.standardizedFileURL != config.rookWorkspaceURL.standardizedFileURL {
      workspaceRoots.append(config.rookWorkspaceURL.path)
    }
    let threadIDRequest = try sendRequest(
      method: "thread/start",
      params: [
        "model": model,
        "cwd": workingDirectoryURL.path,
        "runtimeWorkspaceRoots": workspaceRoots,
        "approvalPolicy": "on-request",
        "approvalsReviewer": "user",
        "sandbox": sandbox,
        "ephemeral": true,
        "serviceName": "rook-computer-operator",
        "config": ["features": ["multi_agent": true, "code_mode_host": true]],
      ],
      to: inputPipe.fileHandleForWriting
    )
    let threadResponse = try waitForResponse(
      id: threadIDRequest,
      stream: stream,
      inputHandle: inputPipe.fileHandleForWriting,
      deadline: deadline,
      finalText: &finalText,
      generatedImageEvents: &generatedImageEvents,
      logHandle: logHandle
    )
    guard let result = threadResponse["result"] as? JSON,
      let thread = result["thread"] as? JSON,
      let threadID = thread["id"] as? String
    else {
      throw RookStreamingError.invalidResponse("Computer Operator thread/start failed")
    }

    var input: [JSON] = [["type": "text", "text": prompt, "text_elements": []]]
    input += inputImageURLs.prefix(3).map {
      ["type": "localImage", "path": $0.path, "detail": "original"]
    }
    let turnRequestID = try sendRequest(
      method: "turn/start",
      params: [
        "threadId": threadID,
        "clientUserMessageId": UUID().uuidString.lowercased(),
        "input": input,
        "cwd": workingDirectoryURL.path,
        "runtimeWorkspaceRoots": workspaceRoots,
        "approvalPolicy": "on-request",
        "approvalsReviewer": "user",
        "model": model,
        "effort": reasoningEffort,
        "summary": "none",
        "outputSchema": schema,
      ],
      to: inputPipe.fileHandleForWriting
    )
    _ = try waitForResponse(
      id: turnRequestID,
      stream: stream,
      inputHandle: inputPipe.fileHandleForWriting,
      deadline: deadline,
      finalText: &finalText,
      generatedImageEvents: &generatedImageEvents,
      logHandle: logHandle
    )

    while true {
      let message = try stream.next(until: deadline)
      try handleServerRequest(message, inputHandle: inputPipe.fileHandleForWriting, logHandle: logHandle)
      capture(message, finalText: &finalText, generatedImageEvents: &generatedImageEvents)
      guard message["method"] as? String == "turn/completed" else { continue }
      guard let params = message["params"] as? JSON,
        let turn = params["turn"] as? JSON,
        turn["status"] as? String == "completed"
      else {
        let detail = (((message["params"] as? JSON)?["turn"] as? JSON)?["error"] as? JSON)?["message"] as? String
        throw RookStreamingError.serverUnavailable(detail ?? "Computer Operator turn failed")
      }
      if finalText == nil { finalText = completedText(from: turn) }
      break
    }

    guard let finalText, !finalText.isEmpty else {
      throw RookStreamingError.invalidResponse("Computer Operator returned no final response")
    }
    let imageJSONL = generatedImageEvents.joined(separator: "\n")
    let generatedImageAssetIDs = RookMediaStore(rootURL: config.mediaURL).storeImages(fromCodexJSONL: imageJSONL)
    return RookOperatorResult(
      responseText: finalText,
      generatedImageAssetIDs: generatedImageAssetIDs
    )
  }

  private func waitForResponse(
    id: Int,
    stream: MessageStream,
    inputHandle: FileHandle,
    deadline: Date,
    finalText: inout String?,
    generatedImageEvents: inout [String],
    logHandle: FileHandle
  ) throws -> JSON {
    while true {
      let message = try stream.next(until: deadline)
      try handleServerRequest(message, inputHandle: inputHandle, logHandle: logHandle)
      capture(message, finalText: &finalText, generatedImageEvents: &generatedImageEvents)
      guard message["method"] == nil, numericID(message["id"]) == id else { continue }
      if let error = message["error"] as? JSON {
        throw RookStreamingError.serverUnavailable(error["message"] as? String ?? "app-server request failed")
      }
      return message
    }
  }

  private func handleServerRequest(_ message: JSON, inputHandle: FileHandle, logHandle: FileHandle) throws {
    guard message["method"] != nil, message["id"] != nil else { return }
    if let decision = RookComputerUseAutoApproval.decision(for: message) {
      try send(
        ["id": message["id"]!, "result": RookComputerUseAutoApproval.response(for: decision)],
        to: inputHandle
      )
      try appendLog(
        "AUTO-APPROVED COMPUTER USE · \(decision.scopeLabel)\n",
        to: logHandle
      )
      return
    }
    try send(
      [
        "id": message["id"]!,
        "error": [
          "code": -32601,
          "message": "Rook only auto-approves Computer Use app access",
        ],
      ],
      to: inputHandle
    )
  }

  private func capture(
    _ message: JSON,
    finalText: inout String?,
    generatedImageEvents: inout [String]
  ) {
    guard message["method"] as? String == "item/completed",
      let params = message["params"] as? JSON,
      var item = params["item"] as? JSON,
      let itemType = item["type"] as? String
    else { return }

    if itemType == "agentMessage", item["phase"] as? String == "final_answer",
      let text = item["text"] as? String, !text.isEmpty
    {
      finalText = text
      return
    }

    let normalizedType: String
    switch itemType {
    case "imageGeneration": normalizedType = "image_generation"
    case "mcpToolCall": normalizedType = "mcp_tool_call"
    case "dynamicToolCall": normalizedType = "custom_tool_call_output"
    default: return
    }
    item["type"] = normalizedType
    if let savedPath = item["savedPath"] { item["saved_path"] = savedPath }
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: ["type": "item.completed", "item": item]
      )
    else { return }
    generatedImageEvents.append(String(decoding: data, as: UTF8.self))
  }

  private func completedText(from turn: JSON) -> String? {
    guard let items = turn["items"] as? [JSON] else { return nil }
    return items.reversed().first(where: {
      $0["type"] as? String == "agentMessage" && $0["phase"] as? String == "final_answer"
    })?["text"] as? String
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

  private func openLog(at url: URL, workingDirectoryURL: URL) throws -> FileHandle {
    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: parent,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    if !FileManager.default.fileExists(atPath: url.path) {
      _ = FileManager.default.createFile(
        atPath: url.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try appendLog(
      "\n[\(ISO8601DateFormatter().string(from: Date()))] COMPUTER OPERATOR · \(workingDirectoryURL.path)\n",
      to: handle
    )
    return handle
  }

  private func appendLog(_ text: String, to handle: FileHandle) throws {
    try handle.write(contentsOf: Data(text.utf8))
  }
}
