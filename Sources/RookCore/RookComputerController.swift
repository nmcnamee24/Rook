import AppKit
import Foundation
import RookKit

struct RookComputerExecution {
  let displayText: String
  let spokenText: String
  let target: String
  let detail: String
}

enum RookComputerControlError: LocalizedError {
  case applicationNotFound(String)
  case invalidWebAddress
  case launchFailed(String)
  case spotifyFailed(String)

  var errorDescription: String? {
    switch self {
    case .applicationNotFound(let name):
      return "I couldn’t find \(name) on this Mac."
    case .invalidWebAddress:
      return "That web address doesn’t look safe or complete."
    case .launchFailed(let detail):
      return "I couldn’t open that: \(detail)"
    case .spotifyFailed(let detail):
      return "Spotify didn’t accept that control: \(detail)"
    }
  }
}

@MainActor
final class RookComputerController {
  typealias Completion = (Result<RookComputerExecution, Error>) -> Void

  private let workspace = NSWorkspace.shared

  func execute(_ intent: RookComputerIntent, completion: @escaping Completion) {
    switch intent {
    case .openApplication(let name):
      openApplication(named: name) { result in
        completion(
          result.map { _ in
            RookComputerExecution(
              displayText: "**\(name)** is open and active.",
              spokenText: "\(name) is open.",
              target: name,
              detail: "Opened and activated"
            )
          })
      }

    case .webSearch(let browser, let query):
      guard let url = searchURL(for: query) else {
        completion(.failure(RookComputerControlError.invalidWebAddress))
        return
      }
      open(url: url, in: browser) { result in
        completion(
          result.map { _ in
            RookComputerExecution(
              displayText: "Opened **\(browser.displayName)** with results for “\(query).”",
              spokenText: "I opened \(browser.displayName) with your search.",
              target: browser.displayName,
              detail: "Search · \(query)"
            )
          })
      }

    case .openWebAddress(let browser, let address):
      guard let url = webURL(from: address) else {
        completion(.failure(RookComputerControlError.invalidWebAddress))
        return
      }
      if let browser {
        open(url: url, in: browser) { result in
          completion(
            result.map { _ in
              RookComputerExecution(
                displayText: "Opened **\(url.host() ?? "that page")** in **\(browser.displayName)**.",
                spokenText: "I opened that page in \(browser.displayName).",
                target: browser.displayName,
                detail: url.host() ?? "Web page opened"
              )
            })
        }
      } else {
        let opened = workspace.open(url)
        if opened {
          completion(
            .success(
              RookComputerExecution(
                displayText: "Opened **\(url.host() ?? "that page")** in your default browser.",
                spokenText: "I opened that page.",
                target: "Default browser",
                detail: url.host() ?? "Web page opened"
              )))
        } else {
          completion(.failure(RookComputerControlError.launchFailed("macOS rejected the request")))
        }
      }

    case .spotify(let action):
      controlSpotify(action, completion: completion)
    }
  }

  private func openApplication(named name: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let applicationURL = applicationURL(named: name) else {
      completion(.failure(RookComputerControlError.applicationNotFound(name)))
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    workspace.openApplication(at: applicationURL, configuration: configuration) { _, error in
      DispatchQueue.main.async {
        if let error {
          completion(.failure(RookComputerControlError.launchFailed(error.localizedDescription)))
        } else {
          completion(.success(()))
        }
      }
    }
  }

  private func open(url: URL, in browser: RookBrowser, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let applicationURL = workspace.urlForApplication(withBundleIdentifier: browser.bundleIdentifier) else {
      completion(.failure(RookComputerControlError.applicationNotFound(browser.displayName)))
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    workspace.open([url], withApplicationAt: applicationURL, configuration: configuration) { _, error in
      DispatchQueue.main.async {
        if let error {
          completion(.failure(RookComputerControlError.launchFailed(error.localizedDescription)))
        } else {
          completion(.success(()))
        }
      }
    }
  }

  private func applicationURL(named rawName: String) -> URL? {
    let name = canonicalApplicationName(rawName)
    if let bundleID = knownBundleIdentifiers[name.lowercased()],
      let url = workspace.urlForApplication(withBundleIdentifier: bundleID)
    {
      return url
    }

    let expected = name.lowercased().hasSuffix(".app") ? name.lowercased() : "\(name.lowercased()).app"
    for directory in applicationDirectories {
      guard
        let contents = try? FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      else { continue }
      if let match = contents.first(where: { $0.lastPathComponent.lowercased() == expected }) {
        return match
      }
    }
    return nil
  }

  private func canonicalApplicationName(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed.lowercased() {
    case "settings", "preferences", "system preferences": return "System Settings"
    case "chrome": return "Google Chrome"
    case "the finder": return "Finder"
    case "my calendar": return "Calendar"
    case "email", "my email": return "Mail"
    default: return trimmed
    }
  }

  private var knownBundleIdentifiers: [String: String] {
    [
      "safari": "com.apple.Safari",
      "google chrome": "com.google.Chrome",
      "chrome": "com.google.Chrome",
      "firefox": "org.mozilla.firefox",
      "arc": "company.thebrowser.Browser",
      "spotify": "com.spotify.client",
      "music": "com.apple.Music",
      "mail": "com.apple.mail",
      "messages": "com.apple.MobileSMS",
      "calendar": "com.apple.iCal",
      "notes": "com.apple.Notes",
      "system settings": "com.apple.systempreferences",
      "terminal": "com.apple.Terminal",
      "activity monitor": "com.apple.ActivityMonitor",
      "finder": "com.apple.finder",
      "chatgpt": "com.openai.chat",
    ]
  }

  private var applicationDirectories: [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      home.appendingPathComponent("Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
    ]
  }

  private func searchURL(for query: String) -> URL? {
    var components = URLComponents(string: "https://www.google.com/search")
    components?.queryItems = [URLQueryItem(name: "q", value: query)]
    return components?.url
  }

  private func webURL(from address: String) -> URL? {
    let candidate = address.lowercased().hasPrefix("http") ? address : "https://\(address)"
    guard let components = URLComponents(string: candidate),
      let scheme = components.scheme?.lowercased(),
      ["http", "https"].contains(scheme),
      components.host != nil,
      components.user == nil,
      components.password == nil
    else { return nil }
    return components.url
  }

  private func controlSpotify(_ action: RookSpotifyAction, completion: @escaping Completion) {
    guard applicationURL(named: "Spotify") != nil else {
      completion(.failure(RookComputerControlError.applicationNotFound("Spotify")))
      return
    }

    let command: String
    switch action {
    case .play: command = "play"
    case .pause: command = "pause"
    case .next: command = "next track"
    case .previous: command = "previous track"
    }
    let source = "tell application id \"com.spotify.client\" to \(command)"
    var details: NSDictionary?
    guard let script = NSAppleScript(source: source) else {
      completion(.failure(RookComputerControlError.spotifyFailed("the automation command could not be created")))
      return
    }
    _ = script.executeAndReturnError(&details)
    if let details {
      let message = (details[NSAppleScript.errorMessage] as? String) ?? "unknown automation error"
      completion(.failure(RookComputerControlError.spotifyFailed(message)))
      return
    }
    completion(
      .success(
        RookComputerExecution(
          displayText: "**Spotify** · \(action.label) complete.",
          spokenText: "Spotify is set.",
          target: "Spotify",
          detail: action.label
        )))
  }
}
