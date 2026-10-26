import Foundation

/// Small preferences the app keeps between runs: where it was last pointed. Not a credential.
public protocol PreferenceStore: Sendable {
    func string(for key: String) -> String?
    func set(_ value: String?, for key: String)
}

public struct UserDefaultsPreferences: PreferenceStore {
    private let suite: String?

    /// `suite`: a defaults domain of the app's own, or the standard one.
    public init(suite: String? = nil) {
        self.suite = suite
    }

    private var defaults: UserDefaults { suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

    public func string(for key: String) -> String? { defaults.string(forKey: key) }

    public func set(_ value: String?, for key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Where what needs the person is told: the Dock badge and the notices of the system. The model decides; this shows.
@MainActor
public protocol AttentionPresenter {
    func setBadge(_ count: Int?)
    func show(_ notice: AttentionNotice)
    func retract(_ ids: [String])
}

/// For where nothing can be told: a test that does not look, and a build with no notifications.
@MainActor
public struct SilentAttention: AttentionPresenter {
    public init() {}
    public func setBadge(_ count: Int?) {}
    public func show(_ notice: AttentionNotice) {}
    public func retract(_ ids: [String]) {}
}

/// Where the system stands on opening the app at login.
public enum LoginItemStatus: Sendable, Equatable {
    case off, on
    /// Registered, and the person has still to approve it in System Settings.
    case requiresApproval
    /// A build the system does not list as a login item.
    case unavailable
}

/// Opening at login, as the system keeps it: the app asks and shows the answer.
@MainActor
public protocol LoginItemControl {
    var status: LoginItemStatus { get }
    func set(_ on: Bool) throws
    /// The place in System Settings where a login item is approved.
    func openSystemSettings()
}

/// For where there is no login item: a test that does not look, and a build the system does not list.
@MainActor
public struct NoLoginItem: LoginItemControl {
    public init() {}
    public var status: LoginItemStatus { .unavailable }
    public func set(_ on: Bool) throws {}
    public func openSystemSettings() {}
}

/// Everything the app's model reaches the outside world through, so a test replaces each: the network, the keychain, the browser, the
/// files, the socket, the clock and the timers.
@MainActor
public struct AppEnvironment {
    public var transport: any HTTPTransport
    public var sessions: any SessionStore
    public var preferences: any PreferenceStore
    public var authenticator: any WebAuthenticator
    public var appVersion: SemanticVersion
    public var deviceName: String
    public var allowsLocalHTTP: Bool
    /// Where per-person files are kept (`outbox/<userId>.json`).
    public var dataDirectory: URL
    /// An `OpenSocket` for this server's canonical address and this session.
    public var openSocket: (_ origin: ServerAddress, _ session: String) -> OpenSocket
    public var schedule: Schedule
    public var random: () -> Double
    public var clock: @Sendable () -> Date
    /// Called with the kept owner of the retained data (a person's id), so what one person left is not sent as another's.
    public var owner: any OwnerMemory
    public var sleep: @Sendable (Duration) async throws -> Void
    public var attention: any AttentionPresenter
    public var loginItem: any LoginItemControl

    public init(
        transport: any HTTPTransport, sessions: any SessionStore, preferences: any PreferenceStore,
        authenticator: any WebAuthenticator,
        appVersion: SemanticVersion, deviceName: String, allowsLocalHTTP: Bool, dataDirectory: URL,
        openSocket: @escaping (ServerAddress, String) -> OpenSocket, schedule: @escaping Schedule,
        random: @escaping () -> Double = { Double.random(in: 0...1) },
        clock: @escaping @Sendable () -> Date = Date.init,
        owner: any OwnerMemory,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        attention: any AttentionPresenter = SilentAttention(),
        loginItem: any LoginItemControl = NoLoginItem()
    ) {
        self.loginItem = loginItem
        self.transport = transport
        self.sessions = sessions
        self.preferences = preferences
        self.authenticator = authenticator
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.allowsLocalHTTP = allowsLocalHTTP
        self.dataDirectory = dataDirectory
        self.attention = attention
        self.openSocket = openSocket
        self.schedule = schedule
        self.random = random
        self.clock = clock
        self.owner = owner
        self.sleep = sleep
    }
}
