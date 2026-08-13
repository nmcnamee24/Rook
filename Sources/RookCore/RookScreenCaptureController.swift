import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import RookKit
import ScreenCaptureKit

struct RookScreenCaptureResult: Sendable {
  let assetID: String
  let imageURL: URL
  let targetLabel: String
  let caption: String
}

enum RookScreenCaptureError: LocalizedError {
  case permissionRequired
  case displayUnavailable
  case windowUnavailable(String)
  case imageEncodingFailed
  case captureFailed(String)

  var errorDescription: String? {
    switch self {
    case .permissionRequired:
      return
        "Screen capture needs permission. Open Rook → Screen & Computer Setup, allow Screen & System Audio Recording, then try again."
    case .displayUnavailable:
      return "Rook couldn’t find an active display to capture."
    case .windowUnavailable(let name):
      return
        "Rook couldn’t find a visible window matching \(name). Open it or use its app or window name, then try again."
    case .imageEncodingFailed:
      return "Rook captured the screen but couldn’t prepare the private image."
    case .captureFailed(let detail):
      return "Rook couldn’t capture that view: \(detail)"
    }
  }
}

@MainActor
final class RookScreenCaptureController {
  private let mediaStore: RookMediaStore
  private let workspace = NSWorkspace.shared

  init(mediaURL: URL) {
    mediaStore = RookMediaStore(rootURL: mediaURL)
  }

  func capture(_ request: RookScreenCaptureRequest) async throws -> RookScreenCaptureResult {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      throw RookScreenCaptureError.permissionRequired
    }

    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
    } catch {
      throw RookScreenCaptureError.captureFailed(error.localizedDescription)
    }

    let capture: (filter: SCContentFilter, configuration: SCStreamConfiguration, label: String, caption: String)
    switch request.target {
    case .mainDisplay:
      guard let display = selectedDisplay(in: content) else {
        throw RookScreenCaptureError.displayUnavailable
      }
      let ownApplications: [SCRunningApplication]
      if let bundleIdentifier = Bundle.main.bundleIdentifier {
        ownApplications = content.applications.filter { $0.bundleIdentifier == bundleIdentifier }
      } else {
        ownApplications = []
      }
      let filter = SCContentFilter(
        display: display,
        excludingApplications: ownApplications,
        exceptingWindows: []
      )
      let configuration = configuration(
        width: display.width,
        height: display.height,
        showsCursor: true
      )
      capture = (filter, configuration, "Screen", "Private local capture of the active display.")

    case .frontmostWindow:
      guard let window = selectedFrontmostWindow(in: content) else {
        throw RookScreenCaptureError.windowUnavailable("the frontmost app")
      }
      capture = windowCapture(window, requestedLabel: "Frontmost window")

    case .namedWindow(let name):
      guard let window = selectedWindow(named: name, in: content) else {
        throw RookScreenCaptureError.windowUnavailable(name)
      }
      capture = windowCapture(window, requestedLabel: name)
    }

    let image: CGImage
    do {
      image = try await SCScreenshotManager.captureImage(
        contentFilter: capture.filter,
        configuration: capture.configuration
      )
    } catch {
      throw RookScreenCaptureError.captureFailed(error.localizedDescription)
    }

    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw RookScreenCaptureError.imageEncodingFailed
    }
    let assetID = try mediaStore.storeImage(data: data, claimedMIMEType: "image/png")
    guard let imageURL = mediaStore.imageURL(for: assetID) else {
      throw RookScreenCaptureError.imageEncodingFailed
    }
    return RookScreenCaptureResult(
      assetID: assetID,
      imageURL: imageURL,
      targetLabel: capture.label,
      caption: capture.caption
    )
  }

  private func selectedDisplay(in content: SCShareableContent) -> SCDisplay? {
    let pointer = NSEvent.mouseLocation
    let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
    let displayID = activeScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    if let displayID,
      let match = content.displays.first(where: { $0.displayID == CGDirectDisplayID(displayID.uint32Value) })
    {
      return match
    }
    return content.displays.first
  }

  private func selectedFrontmostWindow(in content: SCShareableContent) -> SCWindow? {
    let bundleIdentifier = workspace.frontmostApplication?.bundleIdentifier
    return eligibleWindows(in: content)
      .filter { bundleIdentifier == nil || $0.owningApplication?.bundleIdentifier == bundleIdentifier }
      .max(by: { windowArea($0) < windowArea($1) })
      ?? eligibleWindows(in: content).max(by: { windowArea($0) < windowArea($1) })
  }

  private func selectedWindow(named target: String, in content: SCShareableContent) -> SCWindow? {
    let needle = normalized(target)
    guard !needle.isEmpty else { return nil }
    let frontmostBundleIdentifier = workspace.frontmostApplication?.bundleIdentifier
    return eligibleWindows(in: content)
      .compactMap { window -> (window: SCWindow, score: Int, area: CGFloat)? in
        let application = normalized(window.owningApplication?.applicationName ?? "")
        let title = normalized(window.title ?? "")
        var score = 0
        if application == needle { score = max(score, 140) }
        if title == needle { score = max(score, 135) }
        if application.hasPrefix(needle) || needle.hasPrefix(application), !application.isEmpty {
          score = max(score, 115)
        }
        if title.contains(needle), !title.isEmpty { score = max(score, 110) }
        if application.contains(needle), !application.isEmpty { score = max(score, 100) }
        guard score > 0 else { return nil }
        if window.owningApplication?.bundleIdentifier == frontmostBundleIdentifier { score += 8 }
        return (window, score, windowArea(window))
      }
      .max {
        if $0.score != $1.score { return $0.score < $1.score }
        return $0.area < $1.area
      }?
      .window
  }

  private func eligibleWindows(in content: SCShareableContent) -> [SCWindow] {
    content.windows.filter {
      $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width >= 120 && $0.frame.height >= 80
    }
  }

  private func windowCapture(
    _ window: SCWindow,
    requestedLabel: String
  ) -> (filter: SCContentFilter, configuration: SCStreamConfiguration, label: String, caption: String) {
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = configuration(
      width: max(1, Int(window.frame.width * 2)),
      height: max(1, Int(window.frame.height * 2)),
      showsCursor: false
    )
    let appName = window.owningApplication?.applicationName ?? requestedLabel
    return (
      filter,
      configuration,
      requestedLabel,
      "Private local capture of a \(appName) window."
    )
  }

  private func configuration(width: Int, height: Int, showsCursor: Bool) -> SCStreamConfiguration {
    let originalWidth = max(1, width)
    let originalHeight = max(1, height)
    let maximumDimension = 2_560.0
    let scale = min(1, maximumDimension / Double(max(originalWidth, originalHeight)))
    let configuration = SCStreamConfiguration()
    configuration.width = max(1, Int(Double(originalWidth) * scale))
    configuration.height = max(1, Int(Double(originalHeight) * scale))
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.showsCursor = showsCursor
    return configuration
  }

  private func normalized(_ value: String) -> String {
    value
      .lowercased()
      .replacingOccurrences(of: ".app", with: "")
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func windowArea(_ window: SCWindow) -> CGFloat {
    window.frame.width * window.frame.height
  }
}
