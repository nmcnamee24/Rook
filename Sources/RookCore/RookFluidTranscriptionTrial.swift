import FluidAudio
import Foundation

/// Keeps the experimental recognizer fully local and out of the real-time
/// microphone callback. Apple Speech remains available until these models are
/// ready and is the immediate fallback for every failed trial transcription.
actor RookFluidTranscriptionTrial {
  private var manager: AsrManager?
  private var loadTask: Task<AsrManager, Error>?

  func prepare() async throws {
    _ = try await loadManager()
  }

  func transcribeIfReady(pcm16Samples: [Int16]) async throws -> String? {
    guard let manager, pcm16Samples.count >= 1_600 else { return nil }
    let samples = pcm16Samples.map { Float($0) / 32_768 }
    var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
    let result = try await manager.transcribe(samples, decoderState: &decoderState)
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func loadManager() async throws -> AsrManager {
    if let manager { return manager }
    if let loadTask {
      let loaded = try await loadTask.value
      manager = loaded
      self.loadTask = nil
      return loaded
    }

    let task = Task<AsrManager, Error> {
      let models = try await AsrModels.downloadAndLoad(version: .v2)
      return AsrManager(config: .default, models: models)
    }
    loadTask = task
    do {
      let loaded = try await task.value
      manager = loaded
      loadTask = nil
      return loaded
    } catch {
      loadTask = nil
      throw error
    }
  }
}

/// A bounded, lock-protected buffer because AVAudioEngine's tap runs outside
/// the main actor. It retains only the current command and never writes audio
/// to disk.
final class RookCommandAudioCapture: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumSamples: Int
  private var samples: [Int16] = []
  private var isCapturing = false

  init(sampleRate: Int = 16_000, maximumDurationSeconds: Int = 45) {
    maximumSamples = sampleRate * maximumDurationSeconds
  }

  func begin(seed: [Int16] = []) {
    lock.lock()
    samples = Array(seed.suffix(maximumSamples))
    isCapturing = true
    lock.unlock()
  }

  func append(_ newSamples: [Int16]) {
    guard !newSamples.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    guard isCapturing else { return }
    samples.append(contentsOf: newSamples)
    if samples.count > maximumSamples {
      samples.removeFirst(samples.count - maximumSamples)
    }
  }

  func finish() -> [Int16] {
    lock.lock()
    defer { lock.unlock() }
    isCapturing = false
    let result = samples
    samples.removeAll(keepingCapacity: true)
    return result
  }

  func reset() {
    lock.lock()
    isCapturing = false
    samples.removeAll(keepingCapacity: true)
    lock.unlock()
  }
}
