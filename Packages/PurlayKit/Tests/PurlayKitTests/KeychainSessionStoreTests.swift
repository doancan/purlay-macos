import Foundation
import Testing

@testable import PurlayKit

/// The real login keychain, under a service of the test's own that is removed again.
@Suite("KeychainSessionStore", .serialized)
struct KeychainSessionStoreTests {
    private let server = try! ServerAddress.parse("chat.example.com")
    private let other = try! ServerAddress.parse("chat.example.org")

    private func store() -> KeychainSessionStore {
        KeychainSessionStore(service: "dev.purlay.mac.tests." + UUID().uuidString)
    }

    private func session(_ value: String = "value", expires: Date? = nil) -> StoredSession {
        StoredSession(cookie: value, expiresAt: expires, origin: "https://chat.example.com")
    }

    @Test("nothing is stored until something is, and then it comes back as it went")
    func roundTrip() throws {
        let store = store()
        defer { try? store.delete(for: server) }
        #expect(try store.load(for: server) == nil)
        let saved = session("abc", expires: Date(timeIntervalSince1970: 1_900_000_000))
        try store.save(saved, for: server)
        #expect(try store.load(for: server) == saved)
    }

    @Test("saving again replaces the session rather than failing or keeping two")
    func replace() throws {
        let store = store()
        defer { try? store.delete(for: server) }
        try store.save(session("first"), for: server)
        try store.save(session("second"), for: server)
        #expect(try store.load(for: server)?.cookie == "second")
    }

    @Test("each server has its own session, and removing one leaves the other")
    func perServer() throws {
        let store = store()
        defer {
            try? store.delete(for: server)
            try? store.delete(for: other)
        }
        try store.save(session("a"), for: server)
        try store.save(session("b"), for: other)
        #expect(try store.load(for: server)?.cookie == "a")
        try store.delete(for: server)
        #expect(try store.load(for: server) == nil)
        #expect(try store.load(for: other)?.cookie == "b")
    }

    @Test("removing what is not there is not an error")
    func deleteAbsent() throws {
        try store().delete(for: server)
    }

    @Test("a session that ended is a session that is gone: the same service does not see another's")
    func isolatedServices() throws {
        let one = store()
        let two = store()
        defer {
            try? one.delete(for: server)
            try? two.delete(for: server)
        }
        try one.save(session("mine"), for: server)
        #expect(try two.load(for: server) == nil)
    }

    @Test("an item that is not this app's shape is read as no session, and is replaced by the next save")
    func foreignItem() throws {
        let service = "dev.purlay.mac.tests." + UUID().uuidString
        let store = KeychainSessionStore(service: service)
        defer { try? store.delete(for: server) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: server.description, kSecValueData as String: Data("not json".utf8),
        ]
        #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        #expect(try store.load(for: server) == nil)
        try store.save(session("fresh"), for: server)
        #expect(try store.load(for: server)?.cookie == "fresh")
    }
}
