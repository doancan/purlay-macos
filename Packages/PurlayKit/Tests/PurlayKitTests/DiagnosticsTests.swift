import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// "Copy diagnostics": what an operator needs to find a line in the server's log, and nothing that is the person's own (§10).
@Suite("diagnostics")
struct DiagnosticsTests {
    private let at = Date(timeIntervalSince1970: 1_792_940_400)

    private func problem(
        _ endpoint: String = "listNotifications", status: Int? = 500, code: String = "INTERNAL", id: String? = "req-1"
    )
        -> ProblemRecord
    {
        ProblemRecord(at: at, endpoint: endpoint, status: status, code: code, requestID: id)
    }

    private func report(_ problems: [ProblemRecord] = [], connection: String = "open") -> String {
        Diagnostics.report(
            appVersion: "0.3.0", system: "macOS 27.0.1", serverVersion: "0.1.0", contractVersion: 12,
            connection: connection, problems: problems)
    }

    @Test("it names the versions, the connection and the last problems by code and request id")
    func contents() {
        let text = report([problem(), problem("getMe", status: 401, code: "UNAUTHENTICATED", id: "req-2")])
        for line in [
            "0.3.0", "macOS 27.0.1", "0.1.0", "12", "open", "listNotifications", "INTERNAL", "req-1", "UNAUTHENTICATED",
            "req-2", "401",
        ] {
            #expect(text.contains(line), "\(line)")
        }
    }

    @Test("a problem with no status or request id says so without inventing one")
    func partial() {
        let text = report([problem("sendMessage", status: nil, code: "transport.offline", id: nil)])
        #expect(text.contains("transport.offline"))
        #expect(!text.contains("nil"))
    }

    @Test("no problems says none")
    func none() {
        #expect(report().contains("none"))
    }

    @Test("the log keeps the last twenty, newest last, and drops the oldest")
    func bounded() {
        var log = ProblemLog()
        for n in 1...25 { log.record(problem(id: "req-\(n)")) }
        #expect(log.entries.count == ProblemLog.limit)
        #expect(log.entries.first?.requestID == "req-6")
        #expect(log.entries.last?.requestID == "req-25")
    }

    @Test("what a message said and where the server is are never in it: planted words and an address are scanned for")
    func noContent() {
        let planted = "PLANTED-SECRET-WORDS"
        let address = "purlay.example.invalid"
        let text = Diagnostics.report(
            appVersion: "0.3.0", system: "macOS 27", serverVersion: "0.1.0", contractVersion: 12, connection: "open",
            problems: [ProblemRecord(at: at, endpoint: "getMe", status: 500, code: "INTERNAL", requestID: "r")])
        // The report is built from fields that cannot hold either; the scan is for the day one is added that can.
        #expect(!text.contains(planted))
        #expect(!text.contains(address))
        #expect(!text.contains("http"))
    }

    @Test("a code with a path or a word that is not a code is reduced to the code's own characters")
    func sanitised() {
        let text = report([
            problem(code: "BAD CODE with spaces https://purlay.example.invalid/x?token=abc", id: "id with space")
        ])
        #expect(!text.contains("purlay.example.invalid"))
        #expect(!text.contains("token=abc"))
        #expect(!text.contains("with spaces"))
    }
}
