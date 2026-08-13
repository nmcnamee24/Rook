import Foundation
import RookKit
import Security

struct RookOAuthKeychain {
  private let service = "com.noah.rook.oauth"

  func save(_ credential: RookOAuthCredential) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(credential)
    let lookup = query(for: credential.provider)
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

  func load(_ provider: RookOAuthProvider) -> RookOAuthCredential? {
    var lookup = query(for: provider)
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(RookOAuthCredential.self, from: data)
  }

  func delete(_ provider: RookOAuthProvider) throws {
    let status = SecItemDelete(query(for: provider) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError(status: status)
    }
  }

  private func query(for provider: RookOAuthProvider) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: provider.rawValue,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
      SecCopyErrorMessageString(status, nil) as String?
        ?? "Rook could not update the secure connection token."
    }
  }
}
