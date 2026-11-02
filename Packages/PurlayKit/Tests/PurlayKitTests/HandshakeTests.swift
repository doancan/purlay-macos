import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@Suite("Handshake")
struct HandshakeTests {
    private func info(
        contract: Int = 1, minContract: Int? = 1, minApp: String? = "0.1.0",
        appUrl: String = "https://chat.example.com", server: String = "0.2.0"
    ) throws -> ClientInfo {
        let minimum = """
            {"appVersion":\(minApp.map { "\"\($0)\"" } ?? "null"),"contractVersion":\(minContract.map(String.init) ?? "null"),"downloadUrl":null}
            """
        let text = """
            {"server":{"version":"\(server)"},"contractVersion":\(contract),"appUrl":"\(appUrl)",
             "minClient":{"macos":\(minimum)},"auth":{"email":true,"github":true,"oidc":null,"password":true,"signUp":"invite-only"}}
            """
        return try JSONDecoder().decode(ClientInfo.self, from: Data(text.utf8))
    }

    private let app = SemanticVersion("0.1.0")!

    private func outcome(_ info: ClientInfo, app: SemanticVersion? = nil, contract: Int = 1, supported: Set<Int> = [1])
        -> HandshakeOutcome
    {
        Handshake.evaluate(info, appVersion: app ?? self.app, appContract: contract, supported: supported)
    }

    @Test("a server this app can talk to is ready, with the Origin it gave")
    func ready() throws {
        guard case .ready(_, let origin) = outcome(try info()) else {
            Issue.record("not ready")
            return
        }
        #expect(origin.description == "https://chat.example.com")
    }

    @Test("the Origin is the server's own canonical address, not what was typed")
    func canonicalOrigin() throws {
        guard case .ready(_, let origin) = outcome(try info(appUrl: "https://Chat.Example.com/")) else {
            Issue.record("not ready")
            return
        }
        #expect(origin.description == "https://chat.example.com")
    }

    @Test("a server that needs a newer contract than this app speaks is too new for it")
    func appContractTooOld() throws {
        guard
            case .appTooOld(let minimum, _) = outcome(
                try info(contract: 3, minContract: 2), contract: 1, supported: [1])
        else {
            Issue.record("the app was served")
            return
        }
        #expect(minimum.contractVersion == 2)
    }

    @Test(
        "a server that needs a newer app version than this one is too new for it, at the exact boundary",
        arguments: [
            ("0.1.0", "0.1.1", true), ("0.1.0", "0.1.0", false), ("0.2.0", "0.1.9", false),
            ("0.1.0-rc.1", "0.1.0", true),
            ("1.0.0", "1.0.0-rc.1", false),
        ])
    func appVersionTooOld(appVersion: String, minimum: String, refused: Bool) throws {
        let result = outcome(try info(minApp: minimum), app: SemanticVersion(appVersion))
        if refused {
            guard case .appTooOld = result else {
                Issue.record("the app was served below \(minimum)")
                return
            }
        } else {
            guard case .ready = result else {
                Issue.record("the app was refused at \(minimum)")
                return
            }
        }
    }

    @Test("a server with no minimum asks nothing, and one whose minimum cannot be read does not refuse on it")
    func noMinimum() throws {
        guard case .ready = outcome(try info(minContract: nil, minApp: nil)) else {
            Issue.record("refused with no minimum")
            return
        }
        guard case .ready = outcome(try info(minApp: "later")) else {
            Issue.record("refused on an unreadable minimum")
            return
        }
    }

    @Test("a server older than the oldest this build reads is refused, and one it cannot read the version of is not")
    func serverBelowMinimum() throws {
        guard case .serverTooOld = outcome(try info(server: "0.1.9")) else {
            Issue.record("a 0.1 server was served though its channels lack required fields")
            return
        }
        guard case .ready = outcome(try info(server: "0.2.0")) else {
            Issue.record("the minimum itself was refused")
            return
        }
        guard case .ready = outcome(try info(server: "development")) else {
            Issue.record("an unreadable server version was refused")
            return
        }
    }

    @Test("an app newer than the server is served only where the server's contract is one it lists")
    func serverOlder() throws {
        // The app speaks contract 2; the server speaks 1.
        guard
            case .serverTooOld(let seen, _) = outcome(
                try info(contract: 1, minContract: 1), contract: 2, supported: [2])
        else {
            Issue.record("a server below the allowlist was served")
            return
        }
        #expect(seen == 1)
        guard case .ready = outcome(try info(contract: 1, minContract: 1), contract: 2, supported: [1, 2]) else {
            Issue.record("a listed older contract was refused")
            return
        }
    }

    @Test("a server newer than the app is served when its minimum allows this app: the minimum is the server's to set")
    func serverNewer() throws {
        guard case .ready = outcome(try info(contract: 5, minContract: 1), contract: 1, supported: [1]) else {
            Issue.record("a newer server whose minimum allows this app was refused")
            return
        }
    }

    @Test(
        "an appUrl that cannot be an Origin is a finding of its own",
        arguments: [
            "", "not a url", "ftp://x.example.com", "https://x.example.com/path", "http://chat.example.com",
        ])
    func unusableOrigin(appUrl: String) throws {
        guard case .unusableOrigin(let seen, _) = outcome(try info(appUrl: appUrl)) else {
            Issue.record("\(appUrl) was used as an Origin")
            return
        }
        #expect(seen == appUrl)
    }

    @Test("the header is the platform, the app's version and the contract it speaks")
    func header() {
        #expect(
            ClientHeader.value(appVersion: SemanticVersion("1.2.3-rc.1")!, contractVersion: 4)
                == "macos/1.2.3-rc.1 contract/4")
        #expect(
            ClientHeader.value(appVersion: SemanticVersion("0.1.0")!)
                == "macos/0.1.0 contract/\(ContractConstants.contractVersion)")
    }

    @Test("this build lists the contract it was generated from, and nothing else until a person adds one")
    func compatible() {
        #expect(CompatibleContracts.supported == [ContractConstants.contractVersion])
    }
}
