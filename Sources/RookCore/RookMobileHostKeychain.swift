import Foundation
import Security

enum RookMobileHostKeychain {
  private static let service = "com.noah.rook.mobile-host"
  // v1 was initially written by an unsigned `swift run` helper, which can leave
  // the signed app outside that Keychain item's access control list.
  private static let relayAccount = "relay-access-token-v2"

  static func save(sessionToken: String, deviceID: UUID) throws {
    try save(sessionToken, account: deviceID.uuidString.lowercased())
  }

  static func load(deviceID: UUID) -> String? {
    load(account: deviceID.uuidString.lowercased())
  }

  static func remove(deviceID: UUID) {
    remove(account: deviceID.uuidString.lowercased())
  }

  static func saveRelayAccessToken(_ token: String) throws {
    try save(token, account: relayAccount)
  }

  static func loadRelayAccessToken() -> String? {
    load(account: relayAccount)
  }

  static func removeRelayAccessToken() {
    remove(account: relayAccount)
  }

  private static func save(_ value: String, account: String) throws {
    let lookup: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let update = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
    if update == errSecSuccess { return }
    guard update == errSecItemNotFound else { throw KeychainError(status: update) }
    var item = lookup
    item.merge(attributes) { _, new in new }
    let add = SecItemAdd(item as CFDictionary, nil)
    guard add == errSecSuccess else { throw KeychainError(status: add) }
  }

  private static func load(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func remove(account: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
      SecCopyErrorMessageString(status, nil) as String?
        ?? "Rook could not store the private iPhone session."
    }
  }
}
