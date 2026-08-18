//
//  KeychainStore.swift
//  ClaudeKit
//

import Foundation
import Security

/// Keychain-backed storage for the Anthropic API key.
///
/// IMPORTANT: the API key must never be written to the app database, a plist,
/// `UserDefaults`, a crash report, or any log line — not even redacted, not even
/// in debug builds. It lives here and nowhere else, and it is passed straight
/// into the `x-api-key` header. `ClaudeError` descriptions deliberately never
/// interpolate it, and this type never prints it.
public struct KeychainStore: Sendable {

    /// Errors from the Security framework, carrying the raw `OSStatus` so a
    /// support conversation can identify an entitlement problem (-34018) rather
    /// than guessing.
    public enum KeychainError: Error, Equatable, Sendable {
        case unexpectedStatus(OSStatus)
        case invalidData

        /// True when the failure is "this process cannot use the keychain at
        /// all" — an unsigned test binary or a missing entitlement — as opposed
        /// to a real storage failure.
        public var isEntitlementFailure: Bool {
            guard case let .unexpectedStatus(status) = self else { return false }
            // errSecMissingEntitlement / errSecNotAvailable / errSecInteractionNotAllowed
            return status == -34018 || status == errSecNotAvailable || status == errSecInteractionNotAllowed
        }
    }

    public let service: String
    public let account: String

    public init(
        service: String = "com.usenivel.chesscoach.anthropic",
        account: String = "api-key"
    ) {
        self.service = service
        self.account = account
    }

    /// Stores (or replaces) the key.
    public func store(key: String) throws {
        guard let data = key.data(using: .utf8) else { throw KeychainError.invalidData }

        // Delete-then-add rather than SecItemUpdate: it is one round trip
        // fewer in the common "first key" case and cannot leave a stale item
        // with different accessibility attributes behind.
        try? delete()

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        // WhenUnlockedThisDeviceOnly: the key is a device-local secret and must
        // not travel in an iCloud keychain backup to a device the user may no
        // longer control.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Loads the key, or `nil` when none is stored.
    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                throw KeychainError.invalidData
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes the key. Succeeds when there was nothing to remove.
    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Whether a key is stored. Swallows errors — callers use this to decide
    /// whether to show an onboarding prompt, not to diagnose the keychain.
    public var hasKey: Bool {
        ((try? load()) ?? nil) != nil
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Required on macOS: without it the item lands in the legacy file
            // based keychain, which prompts the user and behaves differently
            // from iOS. With it, both platforms use the same data protection
            // keychain and the same code path.
            kSecUseDataProtectionKeychain as String: true
        ]
    }

}

// MARK: - APIKeyProviding

extension KeychainStore: APIKeyProviding {

    public func apiKey() async throws -> String {
        guard let key = try load(), !key.isEmpty else {
            throw ClaudeError.missingAPIKey
        }
        return key
    }

}
