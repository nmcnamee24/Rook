import Foundation

/// A direct intent that may begin read-only preparation while the voice
/// transcript remains open. The prepared result is private and is used only if
/// the final transcript resolves to the exact same intent.
public struct RookStreamingIntentCandidate: Equatable, Sendable {
  public let command: String
  public let capability: RookDirectCapabilityID
  public let adapter: String

  public init(command: String, capability: RookDirectCapabilityID, adapter: String) {
    self.command = command
    self.capability = capability
    self.adapter = adapter
  }
}

public enum RookStreamingIntentPolicy {
  /// Streaming execution is deliberately narrower than the ordinary exact
  /// gate. Only deterministic, side-effect-free Reflex calculations and
  /// conversions may be prepared before the transcript is final.
  public static func candidate(for rawCommand: String) -> RookStreamingIntentCandidate? {
    let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !command.isEmpty,
      case .reflex(let intent) = RookDirectCapabilityGuide.resolve(command),
      isSafeToPrepare(intent)
    else { return nil }

    return RookStreamingIntentCandidate(
      command: command,
      capability: .reflex,
      adapter: "rook_reflex_prewarm"
    )
  }

  public static func isSafeToPrepare(_ intent: RookReflexIntent) -> Bool {
    switch intent {
    case .calculation, .conversion:
      return true
    case .scheduleAlert, .listAlerts, .cancelAlert, .deviceStatus, .volume:
      return false
    }
  }
}

/// Pure stability state used by the voice controller. Timing and microphone
/// quiet checks stay with the host, but this tracker guarantees that one
/// candidate is emitted at most once unless the transcript changes.
public struct RookStreamingIntentTracker: Sendable {
  public let stabilityMilliseconds: Double
  public private(set) var candidate: RookStreamingIntentCandidate?
  private var firstObservedAt: Date?
  private var emitted = false

  public init(stabilityMilliseconds: Double = 350) {
    self.stabilityMilliseconds = max(0, stabilityMilliseconds)
  }

  public mutating func observe(_ command: String, at date: Date = Date()) {
    let next = RookStreamingIntentPolicy.candidate(for: command)
    guard next != candidate else { return }
    candidate = next
    firstObservedAt = next == nil ? nil : date
    emitted = false
  }

  public mutating func ready(at date: Date = Date()) -> RookStreamingIntentCandidate? {
    guard !emitted,
      let candidate,
      let firstObservedAt,
      date.timeIntervalSince(firstObservedAt) * 1_000 >= stabilityMilliseconds
    else { return nil }
    emitted = true
    return candidate
  }

  public mutating func reset() {
    candidate = nil
    firstObservedAt = nil
    emitted = false
  }
}
