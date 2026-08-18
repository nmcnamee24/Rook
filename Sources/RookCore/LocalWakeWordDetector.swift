import Foundation
import RookKit

/// Streams raw 16 kHz mono PCM to Rook's pinned local wake executable. The
/// child process emits only readiness and wake events; ambient audio is kept
/// in memory and never leaves this Mac.
final class LocalWakeWordDetector: @unchecked Sendable {
  typealias ReadyHandler = @Sendable () -> Void
  typealias WakeHandler =
    @Sendable (
      _ phrase: String,
      _ beginSample: Int64?,
      _ endSample: Int64?,
      _ confidence: Double?
    ) -> Void
  typealias FailureHandler = @Sendable (_ reason: String) -> Void

  private let helperURL: URL
  private let modelURL: URL
  private let validationURL: URL
  private let thresholdPercent: Int
  private let queue = DispatchQueue(label: "com.noah.rook.local-wake", qos: .userInteractive)

  private var process: Process?
  private var inputHandle: FileHandle?
  private var outputBuffer = Data()
  private var errorBuffer = Data()
  private var stopping = false
  private var onReady: ReadyHandler?
  private var onWake: WakeHandler?
  private var onFailure: FailureHandler?

  init(helperURL: URL, modelURL: URL, validationURL: URL, thresholdPercent: Int) {
    self.helperURL = helperURL
    self.modelURL = modelURL
    self.validationURL = validationURL
    self.thresholdPercent = thresholdPercent
  }

  func start(
    onReady: @escaping ReadyHandler,
    onWake: @escaping WakeHandler,
    onFailure: @escaping FailureHandler
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.onReady = onReady
      self.onWake = onWake
      self.onFailure = onFailure
      guard self.process == nil else { return }

      guard FileManager.default.isExecutableFile(atPath: self.helperURL.path) else {
        onFailure("Local wake engine is not installed")
        return
      }
      guard FileManager.default.fileExists(atPath: self.modelURL.path) else {
        onFailure("Rook wake model has not been trained")
        return
      }
      guard
        RookWakeValidation.authorization(
          modelURL: self.modelURL,
          manifestURL: self.validationURL
        ) != .unavailable
      else {
        onFailure("Rook wake model is neither validated nor explicitly enabled for trial")
        return
      }

      let process = Process()
      let inputPipe = Pipe()
      let outputPipe = Pipe()
      let errorPipe = Pipe()
      process.executableURL = self.helperURL
      process.arguments = [
        "stream",
        self.modelURL.path,
        String(self.thresholdPercent),
      ]
      process.standardInput = inputPipe
      process.standardOutput = outputPipe
      process.standardError = errorPipe
      self.outputBuffer.removeAll(keepingCapacity: true)
      self.errorBuffer.removeAll(keepingCapacity: true)
      self.stopping = false

      outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        self?.queue.async { self?.consumeOutput(data) }
      }
      errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        self?.queue.async { self?.consumeError(data) }
      }
      process.terminationHandler = { [weak self] terminated in
        self?.queue.async {
          self?.handleTermination(process: terminated, status: terminated.terminationStatus)
        }
      }

      do {
        try process.run()
        self.process = process
        self.inputHandle = inputPipe.fileHandleForWriting
      } catch {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        self.process = nil
        self.inputHandle = nil
        onFailure("Local wake engine could not start")
      }
    }
  }

  func write(samples: [Int16]) {
    guard !samples.isEmpty else { return }
    let data = samples.withUnsafeBytes { Data($0) }
    queue.async { [weak self] in
      guard let self, let inputHandle = self.inputHandle, self.process?.isRunning == true else { return }
      do {
        try inputHandle.write(contentsOf: data)
      } catch {
        self.failRunningProcess("Local wake audio stream stopped")
      }
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.stopping = true
      try? self.inputHandle?.close()
      self.inputHandle = nil
      if self.process?.isRunning == true { self.process?.terminate() }
      self.process = nil
      self.outputBuffer.removeAll(keepingCapacity: false)
      self.errorBuffer.removeAll(keepingCapacity: false)
    }
  }

  private func consumeOutput(_ data: Data) {
    outputBuffer.append(data)
    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      let lineData = outputBuffer[..<newline]
      outputBuffer.removeSubrange(...newline)
      guard
        let line = String(data: lineData, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !line.isEmpty
      else { continue }
      handleLine(line)
    }
  }

  private func consumeError(_ data: Data) {
    errorBuffer.append(data)
    if errorBuffer.count > 4_096 {
      errorBuffer.removeFirst(errorBuffer.count - 4_096)
    }
  }

  private func handleLine(_ line: String) {
    if line == "READY" {
      onReady?()
      return
    }
    guard let event = RookWakeEvent(line: line) else { return }
    onWake?(event.phrase, event.beginSample, event.endSample, event.confidence)
  }

  private func handleTermination(process terminatedProcess: Process, status: Int32) {
    guard process === terminatedProcess else { return }
    let wasStopping = stopping
    stopping = false
    try? inputHandle?.close()
    inputHandle = nil
    process = nil
    guard !wasStopping else { return }

    let detail = String(data: errorBuffer, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if status == 0 {
      onFailure?("Local wake engine exited")
    } else if detail?.isEmpty == false {
      onFailure?("Local wake engine failed")
    } else {
      onFailure?("Local wake engine failed with status \(status)")
    }
  }

  private func failRunningProcess(_ reason: String) {
    onFailure?(reason)
    stopping = true
    if process?.isRunning == true { process?.terminate() }
  }
}
