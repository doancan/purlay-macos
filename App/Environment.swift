import AppKit
import Foundation
import PurlayKit

/// Who the retained data belongs to, kept in the app's defaults beside it.
struct DefaultsOwner: OwnerMemory {
    private let key = "retained-data-owner"
    func load() -> String? { UserDefaults.standard.string(forKey: key) }
    func save(_ owner: String?) {
        if let owner {
            UserDefaults.standard.set(owner, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// The app's real environment: the Keychain, the defaults, the network, the browser and the files, as the sandbox gives them.
@MainActor
enum RealEnvironment {
    static func make(attention: any AttentionPresenter = SilentAttention()) -> AppEnvironment {
        let info = Bundle.main.infoDictionary
        let version =
            SemanticVersion(info?["CFBundleShortVersionString"] as? String ?? "") ?? SemanticVersion(0, 0, 0)
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "dev.purlay.mac", isDirectory: true)
        #if DEBUG
            let allowsLocalHTTP = true
        #else
            let allowsLocalHTTP = false
        #endif
        let clientHeader = ClientHeader.value(appVersion: version)
        return AppEnvironment(
            transport: URLSessionTransport(), sessions: KeychainSessionStore(), preferences: UserDefaultsPreferences(),
            authenticator: SystemBrowserAuthenticator(), appVersion: version,
            deviceName: Host.current().localizedName ?? DeviceName.fallback,
            allowsLocalHTTP: allowsLocalHTTP, dataDirectory: directory,
            openSocket: { origin, session in
                URLSessionSocketTransport(origin: origin.description, clientHeader: clientHeader, cookie: { session })
                    .openSocket(session: session)
            },
            schedule: { milliseconds, work in
                let task = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    if !Task.isCancelled { work() }
                }
                return { task.cancel() }
            },
            owner: DefaultsOwner(), attention: attention, loginItem: SystemLoginItem())
    }

    #if DEBUG
        /// A development shortcut, in debug builds only: point the app at a local server with a session that is already made, so the
        /// screens can be looked at without the browser. `PURLAY_DEV_SERVER=http://localhost:4390 PURLAY_DEV_SESSION=<value>`.
        static func seedDevelopmentSession(_ environment: AppEnvironment) {
            let variables = ProcessInfo.processInfo.environment
            guard let server = variables["PURLAY_DEV_SERVER"], let session = variables["PURLAY_DEV_SESSION"],
                let address = try? ServerAddress.parse(server, allowsLocalHTTP: true)
            else { return }
            try? environment.sessions.save(
                StoredSession(cookie: session, expiresAt: nil, origin: address.description), for: address)
            environment.preferences.set(address.description, for: AppModel.serverKey)
        }
    #endif
}
