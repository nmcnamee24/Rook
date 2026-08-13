import Foundation

public enum RookMediaStoreError: LocalizedError {
  case unsupportedImage
  case imageTooLarge
  case invalidAssetID

  public var errorDescription: String? {
    switch self {
    case .unsupportedImage:
      return "Rook received an unsupported image format."
    case .imageTooLarge:
      return "That image is too large for Rook Canvas."
    case .invalidAssetID:
      return "Rook rejected an invalid private image reference."
    }
  }
}

/// Owns generated images and explicit screen captures that must remain private
/// to the local Rook runtime. Canvas stores only an opaque ID; absolute paths
/// never enter model output.
public struct RookMediaStore: Sendable {
  public static let maximumImageBytes = 50 * 1_024 * 1_024

  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  @discardableResult
  public func storeImage(data: Data, claimedMIMEType: String? = nil) throws -> String {
    guard !data.isEmpty else { throw RookMediaStoreError.unsupportedImage }
    guard data.count <= Self.maximumImageBytes else { throw RookMediaStoreError.imageTooLarge }
    guard let imageType = Self.imageType(for: data, claimedMIMEType: claimedMIMEType) else {
      throw RookMediaStoreError.unsupportedImage
    }

    try prepareDirectory()
    let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    let assetID = "img_\(token).\(imageType.extensionName)"
    let destination = rootURL.appendingPathComponent(assetID, isDirectory: false)
    try RookConfig.writePrivate(data, to: destination)
    return assetID
  }

  @discardableResult
  public func importImage(at sourceURL: URL, claimedMIMEType: String? = nil) throws -> String {
    let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else { throw RookMediaStoreError.unsupportedImage }
    guard (values.fileSize ?? 0) <= Self.maximumImageBytes else {
      throw RookMediaStoreError.imageTooLarge
    }
    return try storeImage(data: Data(contentsOf: sourceURL), claimedMIMEType: claimedMIMEType)
  }

  public func imageURL(for assetID: String?) -> URL? {
    guard let assetID, Self.isValidAssetID(assetID) else { return nil }
    let candidate = rootURL.appendingPathComponent(assetID, isDirectory: false).standardizedFileURL
    guard candidate.deletingLastPathComponent() == rootURL else { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue
    else { return nil }
    return candidate
  }

  public static func isValidAssetID(_ value: String) -> Bool {
    value.range(
      of: #"^img_[a-f0-9]{32}\.(?:png|jpg|webp|gif)$"#,
      options: .regularExpression
    ) != nil
  }

  /// Captures image artifacts from `codex exec --json` without trusting model
  /// text. Current Codex can expose a saved path, raw image-generation base64,
  /// or an image content block returned by the generated-image tool wrapper.
  public func storeImages(fromCodexJSONL text: String) -> [String] {
    var assetIDs: [String] = []
    var fingerprints: Set<String> = []

    for line in text.split(whereSeparator: \.isNewline) {
      guard let data = String(line).data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }

      let type = object["type"] as? String
      if type == "image_generation_end" {
        captureImageGeneration(
          object,
          assetIDs: &assetIDs,
          fingerprints: &fingerprints
        )
        continue
      }

      // Persisted Codex rollouts wrap legacy generation events and raw
      // response items. `codex exec --json` currently omits both image and
      // dynamic-tool items, so this trusted current-session fallback is what
      // lets Rook recover the generated artifact reliably.
      if type == "event_msg", let payload = object["payload"] as? [String: Any],
        payload["type"] as? String == "image_generation_end"
      {
        captureImageGeneration(
          payload,
          assetIDs: &assetIDs,
          fingerprints: &fingerprints
        )
        continue
      }
      if type == "response_item", let payload = object["payload"] as? [String: Any] {
        let payloadType = payload["type"] as? String ?? ""
        if payloadType == "image_generation_call" {
          captureImageGeneration(
            payload,
            assetIDs: &assetIDs,
            fingerprints: &fingerprints
          )
        } else if payloadType == "custom_tool_call_output" || payloadType == "function_call_output" {
          captureToolImages(
            payload["output"],
            assetIDs: &assetIDs,
            fingerprints: &fingerprints
          )
        }
        continue
      }

      guard type == "item.completed", let item = object["item"] as? [String: Any] else { continue }
      let itemType = item["type"] as? String ?? ""
      if itemType == "image_generation" || itemType == "image_generation_call" {
        captureImageGeneration(
          item,
          assetIDs: &assetIDs,
          fingerprints: &fingerprints
        )
      } else if itemType == "mcp_tool_call" || itemType == "custom_tool_call_output"
        || itemType == "function_call_output"
      {
        captureToolImages(
          item["result"] ?? item["output"],
          assetIDs: &assetIDs,
          fingerprints: &fingerprints
        )
      }
    }
    return Array(assetIDs.prefix(3))
  }

  private func captureImageGeneration(
    _ object: [String: Any],
    assetIDs: inout [String],
    fingerprints: inout Set<String>
  ) {
    guard assetIDs.count < 3 else { return }

    if let path = (object["saved_path"] ?? object["savedPath"]) as? String, !path.isEmpty {
      let fingerprint = "path:\(path)"
      if !fingerprints.contains(fingerprint),
        let assetID = try? importImage(at: URL(fileURLWithPath: path))
      {
        fingerprints.insert(fingerprint)
        assetIDs.append(assetID)
        return
      }
    }

    guard let result = object["result"] as? String else { return }
    captureEncodedImage(
      result,
      claimedMIMEType: nil,
      assetIDs: &assetIDs,
      fingerprints: &fingerprints
    )
  }

  private func captureToolImages(
    _ value: Any?,
    assetIDs: inout [String],
    fingerprints: inout Set<String>
  ) {
    guard assetIDs.count < 3, let value else { return }
    if let array = value as? [Any] {
      for item in array {
        captureToolImages(item, assetIDs: &assetIDs, fingerprints: &fingerprints)
        if assetIDs.count >= 3 { return }
      }
      return
    }
    guard let object = value as? [String: Any] else { return }

    let type = object["type"] as? String ?? ""
    if ["image", "input_image", "generated_image"].contains(type) {
      let mimeType = (object["mimeType"] ?? object["mime_type"]) as? String
      if let encoded = (object["data"] ?? object["image_url"] ?? object["imageUrl"]) as? String {
        captureEncodedImage(
          encoded,
          claimedMIMEType: mimeType,
          assetIDs: &assetIDs,
          fingerprints: &fingerprints
        )
      }
      return
    }

    // Only descend through known tool-result containers. This prevents a data
    // URL hallucinated in agent text from becoming a trusted local asset.
    for key in ["content", "content_items", "output", "result"] {
      if let child = object[key] {
        captureToolImages(child, assetIDs: &assetIDs, fingerprints: &fingerprints)
      }
    }
  }

  private func captureEncodedImage(
    _ encodedValue: String,
    claimedMIMEType: String?,
    assetIDs: inout [String],
    fingerprints: inout Set<String>
  ) {
    guard assetIDs.count < 3 else { return }
    let parsed = Self.base64Payload(from: encodedValue, claimedMIMEType: claimedMIMEType)
    guard let parsed else { return }
    let fingerprint = "data:\(parsed.encoded.count):\(parsed.encoded.prefix(48))"
    guard !fingerprints.contains(fingerprint),
      let data = Data(base64Encoded: parsed.encoded, options: [.ignoreUnknownCharacters]),
      let assetID = try? storeImage(data: data, claimedMIMEType: parsed.mimeType)
    else { return }
    fingerprints.insert(fingerprint)
    assetIDs.append(assetID)
  }

  private func prepareDirectory() throws {
    try FileManager.default.createDirectory(
      at: rootURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
  }

  private static func base64Payload(
    from value: String,
    claimedMIMEType: String?
  ) -> (encoded: String, mimeType: String?)? {
    if value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ",") {
      let header = String(value[..<comma])
      guard header.lowercased().hasSuffix(";base64") else { return nil }
      let mimeType = header.dropFirst("data:".count).split(separator: ";").first.map(String.init)
      return (String(value[value.index(after: comma)...]), mimeType)
    }
    guard !value.isEmpty else { return nil }
    return (value, claimedMIMEType)
  }

  private static func imageType(
    for data: Data,
    claimedMIMEType: String?
  ) -> (extensionName: String, mimeType: String)? {
    let bytes = [UInt8](data.prefix(12))
    if bytes.count >= 8, bytes[0..<8].elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]) {
      return ("png", "image/png")
    }
    if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
      return ("jpg", "image/jpeg")
    }
    if bytes.count >= 6, String(bytes: bytes[0..<6], encoding: .ascii)?.hasPrefix("GIF8") == true {
      return ("gif", "image/gif")
    }
    if bytes.count >= 12,
      String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
      String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP"
    {
      return ("webp", "image/webp")
    }
    _ = claimedMIMEType
    return nil
  }
}
