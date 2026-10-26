import Foundation
import PurlayContract

/// The contract versions this build can talk to: the one it was generated from, and by explicit allowlist the earlier
/// ones it was tested against. A version is added here by a person, with a test, never by a default (§6.4).
public enum CompatibleContracts {
    public static let supported: Set<Int> = [ContractConstants.contractVersion]
}

/// The one header every request and the socket upgrade carries: what the server gates on (D-187).
public enum ClientHeader {
    public static func value(appVersion: SemanticVersion, contractVersion: Int = ContractConstants.contractVersion)
        -> String
    {
        "macos/\(appVersion) contract/\(contractVersion)"
    }
}

/// What the server's answer to `GET /api/client` means for this app.
public enum HandshakeOutcome: Sendable, Equatable {
    /// Talk to it. `origin` is the `Origin` the socket upgrade must carry (M-15), the server's own spelling.
    case ready(ClientInfo, origin: ServerAddress)
    /// The server needs a newer app than this one. The sheet offers an update and shows the address; it never loops.
    case appTooOld(minimum: ClientMinimum, server: ClientInfo)
    /// The server is older than this app can talk to: its contract is not one this build lists.
    case serverTooOld(serverContract: Int, server: ClientInfo)
    /// The server gave an `appUrl` the app cannot use as an `Origin`.
    case unusableOrigin(String, server: ClientInfo)
}

public enum Handshake {
    /// Both directions (§6.4), decided from what the server said and what this build is.
    public static func evaluate(
        _ info: ClientInfo, appVersion: SemanticVersion, appContract: Int = ContractConstants.contractVersion,
        supported: Set<Int> = CompatibleContracts.supported, allowsLocalHTTP: Bool = false
    ) -> HandshakeOutcome {
        let minimum = info.minClient.macos
        if let needed = minimum.contractVersion, appContract < needed {
            return .appTooOld(minimum: minimum, server: info)
        }
        if let text = minimum.appVersion {
            // A minimum the app cannot read is not a reason to refuse: the server's own check, at the edge, still stands.
            if let needed = SemanticVersion(text), appVersion < needed {
                return .appTooOld(minimum: minimum, server: info)
            }
        }
        // An app newer than the server is allowed only where it lists that contract as one it was tested against.
        if info.contractVersion < appContract && !supported.contains(info.contractVersion) {
            return .serverTooOld(serverContract: info.contractVersion, server: info)
        }
        guard let origin = try? ServerAddress.parse(info.appUrl, allowsLocalHTTP: allowsLocalHTTP) else {
            return .unusableOrigin(info.appUrl, server: info)
        }
        return .ready(info, origin: origin)
    }
}
