import Foundation
import PurlayKit
import Synchronization

/// Keeps sessions in memory, for the tests that are not about the Keychain.
public final class InMemorySessionStore: SessionStore {
    private struct State {
        var sessions: [String: StoredSession] = [:]
        var saves = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// How many times a session was written.
    public var saves: Int { state.withLock { $0.saves } }

    public func load(for server: ServerAddress) throws -> StoredSession? {
        state.withLock { $0.sessions[server.description] }
    }

    public func save(_ session: StoredSession, for server: ServerAddress) throws {
        state.withLock {
            $0.sessions[server.description] = session
            $0.saves += 1
        }
    }

    public func delete(for server: ServerAddress) throws {
        state.withLock { $0.sessions[server.description] = nil }
    }
}

/// Answers the sign-in page as a script says: with the callback, or with the person closing it.
public actor ScriptedAuthenticator: WebAuthenticator {
    public enum Answer: Sendable {
        case callback(@Sendable (URL) -> URL)
        case fail(WebAuthenticatorError)
    }

    private var answers: [Answer]
    public private(set) var pages: [URL] = []
    public private(set) var schemes: [String] = []

    public init(_ answers: [Answer]) {
        self.answers = answers
    }

    public func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        pages.append(url)
        schemes.append(callbackScheme)
        guard !answers.isEmpty else { throw WebAuthenticatorError.failed("nothing was scripted") }
        switch answers.removeFirst() {
        case .callback(let make): return make(url)
        case .fail(let error): throw error
        }
    }

    /// The callback the server would hand back for this page: its own state and a code.
    public static func answering(code: String = String(repeating: "a", count: 64)) -> Answer {
        .callback { page in
            let state =
                URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?
                .value ?? ""
            return URL(string: "purlay://auth?code=\(code)&state=\(state)")!
        }
    }
}

/// Counts how often the data it stands for was removed, and can look at what the world was like at that moment.
public final class RecordingWiper: UserDataWiper {
    private let state = Mutex(0)
    private let onWipe: @Sendable () async -> Void

    public init(onWipe: @escaping @Sendable () async -> Void = {}) {
        self.onWipe = onWipe
    }

    public var wipes: Int { state.withLock { $0 } }

    public func wipe() async {
        state.withLock { $0 += 1 }
        await onWipe()
    }
}

public final class InMemoryOwnerMemory: OwnerMemory {
    private let state: Mutex<String?>

    public init(_ owner: String? = nil) {
        state = Mutex(owner)
    }

    public func load() -> String? { state.withLock { $0 } }
    public func save(_ owner: String?) { state.withLock { $0 = owner } }
}
