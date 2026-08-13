import Foundation
import RookKit

final class KokoroSpeechSynthesizer: @unchecked Sendable {
  private struct Request: Encodable {
    let id: String
    let text: String
    let voice: String
    let speed: Double
    let output: String
  }

  private struct Response: Decodable {
    let event: String?
    let id: String?
    let ok: Bool?
    let error: String?
  }

  private enum SynthesizerError: LocalizedError {
    case missingRuntime(String)
    case invalidResponse
    case workerFailure(String)

    var errorDescription: String? {
      switch self {
      case .missingRuntime(let path):
        return "Missing Kokoro runtime component: \(path)"
      case .invalidResponse:
        return "Kokoro returned an invalid response"
      case .workerFailure(let message):
        return message
      }
    }
  }

  private let queue = DispatchQueue(label: "com.noah.rook.kokoro", qos: .userInitiated)
  private let pythonURL: URL
  private let modelURL: URL
  private let voicesURL: URL
  private let workerURL: URL?
  private let logURL: URL

  private var process: Process?
  private var inputHandle: FileHandle?
  private var outputHandle: FileHandle?
  private var logHandle: FileHandle?

  init(config: RookConfig) {
    let ttsDirectory = config.rookWorkspaceURL.appendingPathComponent("tts", isDirectory: true)
    pythonURL = ttsDirectory.appendingPathComponent(".venv/bin/python")
    modelURL = ttsDirectory.appendingPathComponent("kokoro-v1.0.onnx")
    voicesURL = ttsDirectory.appendingPathComponent("voices-v1.0.bin")
    workerURL = Bundle.main.resourceURL?.appendingPathComponent("kokoro_worker.py")
    logURL = config.stateURL.appendingPathComponent("tts.log")
  }

  deinit {
    stopWorker()
  }

  func speak(
    _ text: String,
    voice: String,
    speed: Double,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    queue.async { [self] in
      let succeeded: Bool
      do {
        let audioURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("rook-\(UUID().uuidString.lowercased()).wav")
        defer { try? FileManager.default.removeItem(at: audioURL) }

        try synthesize(text, voice: voice, speed: speed, to: audioURL)
        try play(audioURL)
        succeeded = true
      } catch {
        log("Kokoro speech failed: \(error.localizedDescription)")
        stopWorker()
        succeeded = false
      }
      Task { @MainActor in
        completion(succeeded)
      }
    }
  }

  private func synthesize(_ text: String, voice: String, speed: Double, to audioURL: URL) throws {
    try ensureWorker()
    guard let inputHandle, let outputHandle else {
      throw SynthesizerError.invalidResponse
    }

    let identifier = UUID().uuidString.lowercased()
    let request = Request(
      id: identifier,
      text: text,
      voice: voice,
      speed: speed,
      output: audioURL.path
    )
    var payload = try JSONEncoder().encode(request)
    payload.append(0x0A)
    try inputHandle.write(contentsOf: payload)

    let response = try JSONDecoder().decode(Response.self, from: readLine(from: outputHandle))
    guard response.id == identifier, response.ok == true else {
      throw SynthesizerError.workerFailure(response.error ?? "Kokoro could not synthesize speech")
    }
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      throw SynthesizerError.invalidResponse
    }
  }

  private func ensureWorker() throws {
    if process?.isRunning == true, inputHandle != nil, outputHandle != nil {
      return
    }
    stopWorker()

    for url in [pythonURL, modelURL, voicesURL] where !FileManager.default.fileExists(atPath: url.path) {
      throw SynthesizerError.missingRuntime(url.path)
    }
    guard let workerURL, FileManager.default.fileExists(atPath: workerURL.path) else {
      throw SynthesizerError.missingRuntime(workerURL?.path ?? "kokoro_worker.py")
    }

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let process = Process()
    process.executableURL = pythonURL
    process.arguments = [
      workerURL.path,
      "--model", modelURL.path,
      "--voices", voicesURL.path,
    ]
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = try openLog()

    try process.run()
    self.process = process
    inputHandle = inputPipe.fileHandleForWriting
    outputHandle = outputPipe.fileHandleForReading

    let response = try JSONDecoder().decode(Response.self, from: readLine(from: outputPipe.fileHandleForReading))
    guard response.event == "ready" else {
      throw SynthesizerError.workerFailure(response.error ?? "Kokoro worker did not become ready")
    }
  }

  private func readLine(from handle: FileHandle) throws -> Data {
    var line = Data()
    while line.count <= 65_536 {
      guard let byte = try handle.read(upToCount: 1), !byte.isEmpty else {
        throw SynthesizerError.invalidResponse
      }
      if byte[byte.startIndex] == 0x0A {
        return line
      }
      line.append(byte)
    }
    throw SynthesizerError.invalidResponse
  }

  private func play(_ audioURL: URL) throws {
    let player = Process()
    player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    player.arguments = [audioURL.path]
    try player.run()
    player.waitUntilExit()
    guard player.terminationStatus == 0 else {
      throw SynthesizerError.workerFailure("Audio playback failed")
    }
  }

  private func openLog() throws -> FileHandle {
    if let logHandle {
      return logHandle
    }
    if !FileManager.default.fileExists(atPath: logURL.path) {
      FileManager.default.createFile(
        atPath: logURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      )
    }
    let handle = try FileHandle(forWritingTo: logURL)
    try handle.seekToEnd()
    logHandle = handle
    return handle
  }

  private func log(_ message: String) {
    guard let data = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n".data(using: .utf8) else {
      return
    }
    do {
      let handle = try openLog()
      try handle.write(contentsOf: data)
    } catch {
      // Speech fallback still works even if diagnostics cannot be written.
    }
  }

  private func stopWorker() {
    try? inputHandle?.close()
    try? outputHandle?.close()
    inputHandle = nil
    outputHandle = nil
    if process?.isRunning == true {
      process?.terminate()
    }
    process = nil
    try? logHandle?.close()
    logHandle = nil
  }
}
