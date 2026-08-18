//
//  KeychainStoreTests.swift
//  ClaudeKitTests
//

import Foundation
import Testing
@testable import ClaudeKit

/// Works out, once, which keychain this process can actually reach.
///
/// The app always uses the data protection keychain. An unsigned `swift test`
/// binary cannot: `SecItemAdd` returns -34018 (`errSecMissingEntitlement`),
/// because the data protection keychain requires an application-identifier
/// entitlement backed by a provisioning profile. Signing the binary with a
/// development certificate is not enough — this was verified rather than
/// assumed.
///
/// So the round-trip tests run against the legacy keychain when that is all
/// that is available, which exercises the same `SecItem` calls, the same
/// attributes and the same error mapping — everything except which store the
/// bytes land in. Under a signed Xcode test host they run against the real
/// thing without changing.
enum KeychainAvailability {

    static let usesDataProtectionKeychain: Bool = {
        let store = KeychainStore(service: "com.usenivel.chesscoach.tests.probe", account: "probe")
        do {
            try store.store(key: "probe")
            try? store.delete()
            return true
        } catch {
            return false
        }
    }()

    static let isAvailable: Bool = {
        guard !usesDataProtectionKeychain else { return true }
        let store = makeStore(service: "com.usenivel.chesscoach.tests.probe.legacy")
        do {
            try store.store(key: "probe")
            try? store.delete()
            return true
        } catch {
            return false
        }
    }()

    static func makeStore(service: String) -> KeychainStore {
        KeychainStore(
            service: service,
            account: "api-key",
            usesDataProtectionKeychain: usesDataProtectionKeychain
        )
    }

}

@Suite("Keychain storage", .enabled(if: KeychainAvailability.isAvailable))
struct KeychainStoreTests {

    /// A unique service per test so runs never collide with each other or with
    /// the app's real key.
    private func makeStore() -> KeychainStore {
        KeychainAvailability.makeStore(service: "com.usenivel.chesscoach.tests.\(UUID().uuidString)")
    }

    @Test("Store, load and delete round-trip")
    func roundTrip() throws {
        let store = makeStore()
        defer { try? store.delete() }

        #expect(store.hasKey == false)
        #expect(try store.load() == nil)

        try store.store(key: "sk-ant-api03-round-trip")

        #expect(store.hasKey)
        #expect(try store.load() == "sk-ant-api03-round-trip")

        try store.delete()

        #expect(store.hasKey == false)
        #expect(try store.load() == nil)
    }

    @Test("Storing twice replaces rather than duplicating")
    func storeReplaces() throws {
        let store = makeStore()
        defer { try? store.delete() }

        try store.store(key: "first")
        try store.store(key: "second")

        #expect(try store.load() == "second")
    }

    @Test("Deleting a key that isn't there succeeds")
    func deleteIsIdempotent() throws {
        let store = makeStore()

        try store.delete()
        try store.delete()
    }

    @Test("The store supplies the key to the client")
    func actsAsKeyProvider() async throws {
        let store = makeStore()
        defer { try? store.delete() }

        try store.store(key: "sk-ant-provider")
        #expect(try await store.apiKey() == "sk-ant-provider")
    }

    @Test("An empty keychain reports a missing key rather than an empty one")
    func missingKeyIsTyped() async throws {
        let store = makeStore()

        await #expect(throws: ClaudeError.missingAPIKey) {
            _ = try await store.apiKey()
        }
    }

    @Test("Two stores with different services do not see each other's keys")
    func storesAreIsolated() throws {
        let first = makeStore()
        let second = makeStore()
        defer {
            try? first.delete()
            try? second.delete()
        }

        try first.store(key: "one")

        #expect(try second.load() == nil)
        #expect(try first.load() == "one")
    }

}

/// The parts of the store that never touch the Security framework, so they run
/// everywhere.
@Suite("Keychain store configuration")
struct KeychainStoreConfigurationTests {

    @Test("Entitlement failures are distinguishable from real storage failures")
    func entitlementFailureDetection() {
        // -34018 is errSecMissingEntitlement, which has no public constant.
        #expect(KeychainStore.KeychainError.unexpectedStatus(-34018).isEntitlementFailure)
        #expect(KeychainStore.KeychainError.unexpectedStatus(errSecNotAvailable).isEntitlementFailure)
        #expect(KeychainStore.KeychainError.unexpectedStatus(errSecDuplicateItem).isEntitlementFailure == false)
        #expect(KeychainStore.KeychainError.invalidData.isEntitlementFailure == false)
    }

    @Test("The default service and account are the app's, on the data protection keychain")
    func defaults() {
        let store = KeychainStore()
        #expect(store.service == "com.usenivel.chesscoach.anthropic")
        #expect(store.account == "api-key")
        // The public initialiser must never produce a legacy-keychain store.
        #expect(store.usesDataProtectionKeychain)
    }

}
