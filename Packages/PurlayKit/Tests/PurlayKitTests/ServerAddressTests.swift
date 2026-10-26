import Testing

@testable import PurlayKit

@Suite("ServerAddress")
struct ServerAddressTests {
    @Test(
        "an address as it is typed becomes an origin",
        arguments: [
            ("chat.example.com", "https://chat.example.com"), ("https://chat.example.com", "https://chat.example.com"),
            ("https://chat.example.com/", "https://chat.example.com"),
            ("  https://chat.example.com  ", "https://chat.example.com"),
            ("HTTPS://Chat.Example.COM", "https://chat.example.com"),
            ("chat.example.com:8443", "https://chat.example.com:8443"),
            ("https://chat.example.com:443", "https://chat.example.com"),
            ("https://10.0.0.119:8080", "https://10.0.0.119:8080"),
        ])
    func origins(typed: String, expected: String) throws {
        #expect(try ServerAddress.parse(typed).description == expected)
    }

    @Test(
        "this machine may be reached over http in a development build, and only then",
        arguments: [
            ("localhost:3000", "http://localhost:3000"), ("http://localhost:3000", "http://localhost:3000"),
            ("127.0.0.1:4173", "http://127.0.0.1:4173"), ("http://127.0.0.1", "http://127.0.0.1"),
        ])
    func localDevelopment(typed: String, expected: String) throws {
        #expect(try ServerAddress.parse(typed, allowsLocalHTTP: true).description == expected)
        // Without the allowance a bare local host is `https`, and an `http` one is refused.
        if typed.hasPrefix("http://") {
            #expect(throws: ServerAddress.Problem.insecure) { _ = try ServerAddress.parse(typed) }
        }
    }

    @Test(
        "http for a host that is not this machine is refused even in a development build",
        arguments: [
            "http://chat.example.com", "http://10.0.0.119", "http://192.168.1.2:3000", "http://localhost.evil.test",
            "http://127.0.0.1.evil.test",
        ])
    func insecure(typed: String) {
        #expect(throws: ServerAddress.Problem.insecure) { _ = try ServerAddress.parse(typed, allowsLocalHTTP: true) }
    }

    @Test(
        "what is not the address of a server is refused, and says which way",
        arguments: [
            ("", ServerAddress.Problem.empty), ("   ", .empty), ("chat example.com", .unreadable),
            ("https://chat.example.com\n", .empty),
            ("ftp://chat.example.com", .notAWebAddress),
            ("file:///etc/hosts", .notAWebAddress), ("javascript:alert(1)", .notAWebAddress),
            ("https://user:pw@chat.example.com", .hasCredentials), ("https://user@chat.example.com", .hasCredentials),
            ("https://chat.example.com/app", .hasMoreThanAHost), ("https://chat.example.com?x=1", .hasMoreThanAHost),
            ("https://chat.example.com#x", .hasMoreThanAHost), ("https://", .unreadable),
            ("https://:8080", .unreadable),
            ("https://chat.example.com:0", .unreadable), ("https://chat.example.com:99999", .unreadable),
        ])
    func refuses(typed: String, problem: ServerAddress.Problem) throws {
        if typed == "https://chat.example.com\n" {
            // Surrounding whitespace is trimmed, as a pasted address has it: this one is fine.
            #expect(try ServerAddress.parse(typed).description == "https://chat.example.com")
            return
        }
        #expect(throws: problem) { _ = try ServerAddress.parse(typed) }
    }

    @Test("two spellings of one origin are equal, so a server is not remembered twice")
    func equality() throws {
        #expect(try ServerAddress.parse("Chat.Example.com") == ServerAddress.parse("https://chat.example.com/"))
    }
}
