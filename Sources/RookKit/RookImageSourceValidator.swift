import Foundation

/// Shared URL policy for online Canvas images and source attribution.
public enum RookImageSourceValidator {
  public static func publicHTTPSURL(_ value: String) -> URL? {
    let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: cleaned),
      components.scheme?.lowercased() == "https",
      let rawHost = components.host?.lowercased(),
      !rawHost.isEmpty,
      components.user == nil,
      components.password == nil,
      !isLocalOrPrivateHost(rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    else { return nil }

    let secretQueryNames: Set<String> = [
      "access_token", "api_key", "apikey", "auth", "authorization", "key", "signature", "sig", "token",
    ]
    let trackingQueryNames: Set<String> = ["fbclid", "gclid", "mc_cid", "mc_eid"]
    if let items = components.queryItems {
      guard !items.contains(where: { secretQueryNames.contains($0.name.lowercased()) }) else { return nil }
      components.queryItems = items.filter {
        let name = $0.name.lowercased()
        return !name.hasPrefix("utm_") && !trackingQueryNames.contains(name)
      }
      if components.queryItems?.isEmpty == true { components.queryItems = nil }
    }
    return components.url
  }

  public static func sanitizedPublicHTTPSString(_ value: String) -> String {
    guard let url = publicHTTPSURL(value) else { return "" }
    return String(url.absoluteString.prefix(2_000))
  }

  private static func isLocalOrPrivateHost(_ host: String) -> Bool {
    if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1"
      || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
    {
      return true
    }
    if host.contains(":"),
      host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe8") || host.hasPrefix("fe9")
        || host.hasPrefix("fea") || host.hasPrefix("feb")
    {
      return true
    }
    let parts = host.split(separator: ".").compactMap { Int($0) }
    guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
    let first = parts[0]
    let second = parts[1]
    return first == 0 || first == 10 || first == 127 || first >= 224
      || (first == 100 && (64...127).contains(second))
      || (first == 169 && second == 254)
      || (first == 172 && (16...31).contains(second))
      || (first == 192 && second == 168)
  }
}
