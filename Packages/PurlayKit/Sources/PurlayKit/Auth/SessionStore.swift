import Foundation
import Security

/// Where the session is kept between runs. One per server address (M-9).
public protocol SessionStore: Sendable {
    func load(for server: ServerAddress) throws -> StoredSession?
    func save(_ session: StoredSession, for server: ServerAddress) throws
    func delete(for server: ServerAddress) throws
}

public struct KeychainError: Error, Sendable, Equatable {
    public let status: Int32
    public let operation: String

    public init(status: Int32, operation: String) {
        self.status = status
        self.operation = operation
    }
}

/// The session as a generic password in the login keychain (M-22): file-based, so it works in the sandbox and under the
/// hardened runtime without an entitlement; no iCloud, and no reliance on `kSecAttrAccessible`.
public struct KeychainSessionStore: SessionStore {
    private let service: String

    public init(service: String = "dev.purlay.mac.session") {
        self.service = service
    }

    private func query(for server: ServerAddress) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: server.description,
            kSecAttrSynchronizable as String: false,
        ]
    }

    public func load(for server: ServerAddress) throws -> StoredSession? {
        var request = query(for: server)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status, operation: "read")
        }
        // An item this app did not write, or an older shape: treated as no session, so the person signs in again, rather
        // than as a failure the person cannot act on. It is replaced by the next save.
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession, for server: ServerAddress) throws {
        let data = try JSONEncoder().encode(session)
        var add = query(for: server)
        add[kSecValueData as String] = data
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(for: server) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status, operation: "write") }
    }

    public func delete(for server: ServerAddress) throws {
        let status = SecItemDelete(query(for: server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }
}
