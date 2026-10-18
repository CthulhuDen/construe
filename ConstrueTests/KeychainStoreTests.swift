import Foundation
import Testing
@testable import Construe

/// Uses a test-only account so the real API key is never read or overwritten.
@MainActor
struct KeychainStoreTests {
    private let store = KeychainStore(
        service: Bundle.main.bundleIdentifier ?? "Construe",
        account: "tests-\(UUID().uuidString)"
    )

    @Test func roundTrip() throws {
        defer { try? store.delete() }

        #expect(store.read() == nil)

        try store.save("sk-ant-first")
        #expect(store.read() == "sk-ant-first")

        try store.save("sk-ant-second")
        #expect(store.read() == "sk-ant-second")

        try store.delete()
        #expect(store.read() == nil)
    }

    @Test func deletingMissingItemSucceeds() throws {
        try store.delete()
    }
}
