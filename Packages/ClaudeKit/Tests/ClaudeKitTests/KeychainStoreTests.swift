//
//  KeychainStoreTests.swift
//  ClaudeKitTests
//

import Foundation
import Testing
@testable import ClaudeKit

/// Probes once whether this process can use the data protection keychain.
///
/// An unsigned `swift test` binary cannot: `SecItemAdd` returns -34018
/// (`errSecMissingEntitlement`) because there is no application-identifier
/// entitlement to scope the item to. Rather than fail the suite over a machine
/// configuration issue, the tests below report as skipped there, and run for
/// real wherever the keychain is genuinely available — Xcode's signed test
/// host, simulators, devices, or CI with a signing identity.
enum KeychainAvailability {

    static let isAvailable: Bool = {
        let store = KeychainStore(service: "com.usenivel.chesscoach.tests.probe", account: "probe")
        do {
            try store.store(key: "probe")
            try? store.delete()
            return true
        } catch {
            return false
        }
    }()

}

@Suite("Keychain storage", .enabled(if: KeychainAvailability.isAvailable))
struct KeychainStoreTests {

    /// A unique service per test so runs never collide with each other or with
    /// the app's real key.
    private func makeStore() -> KeychainStore {
        KeychainStore(service: "com.usenivel.chesscoach.tests.\(UUID().uuidString)", account: "api-key")
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

    @Test("The default service and account are the app's")
    func defaults() {
        let store = KeychainStore()
        #expect(store.service == "com.usenivel.chesscoach.anthropic")
        #expect(store.account == "api-key")
    }

}
