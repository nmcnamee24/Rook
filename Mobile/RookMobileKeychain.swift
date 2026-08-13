import Foundation
import Security

enum RookMobileKeychain {
  private static let service = "com.noah.rook.mobile"
  private static let account = "mac-session-token"
  private static let relayAccount = "relay-access-token"

  static func save(sessionToken: String) throws {
    try save(sessionToken, account: account)
  }

  static func loadSessionToken() -> String? {
    load(account: account)
  }

  static func saveRelayAccessToken(_ token: String) throws {
    try save(token, account: relayAccount)
  }

  static func loadRelayAccessToken() -> String? {
    load(account: relayAccount)
  }

  private static func save(_ value: String, account: String) throws {
    let data = Data(value.utf8)
    let lookup: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainError(status: updateStatus)
    }
    var item = lookup
    item.merge(attributes) { _, new in new }
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
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

  static func clear() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
    var relayQuery = query
    relayQuery[kSecAttrAccount as String] = relayAccount
    SecItemDelete(relayQuery as CFDictionary)
  }

  private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
      SecCopyErrorMessageString(status, nil) as String?
        ?? "Rook could not store the pairing token."
    }
  }
}
