import Foundation
import Testing

@testable import PurlayContract

/// What the generated types do at the edges: what they tolerate because the server is allowed to grow, and what they
/// refuse because a contract that drifted should be loud and not quiet.
@Suite("Generated types")
struct BehaviourTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    private func json(_ value: some Encodable) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    // MARK: What the server may add

    @Test("a value an enumeration did not have is `unknown`, and is written back as it came")
    func unknownEnumerationValue() throws {
        let code = try decode(ErrorCode.self, "\"SOMETHING_FROM_THE_FUTURE\"")
        #expect(code == .unknown("SOMETHING_FROM_THE_FUTURE"))
        #expect(try json(code) == .string("SOMETHING_FROM_THE_FUTURE"))
        #expect(try decode(ErrorCode.self, "\"VALIDATION_FAILED\"") == .validationFailed)
    }

    @Test("a number an enumeration of numbers did not have is `unknown` too")
    func unknownNumber() throws {
        #expect(try decode(IncidentSeverity.self, "9") == .unknown(9))
        #expect(try decode(IncidentSeverity.self, "2") == .v2)
        #expect(try json(IncidentSeverity.v3) == .integer(3))
    }

    @Test("a frame the client was not built for is held whole, and not a failure")
    func unknownFrame() throws {
        let text = #"{"event":"FROM_THE_FUTURE","ts":1.5,"data":{"x":[1,2]}}"#
        let frame = try decode(ServerFrame.self, text)
        guard case .unknown(let tag, let payload) = frame else {
            Issue.record("not held as unknown: \(frame)")
            return
        }
        #expect(tag == "FROM_THE_FUTURE")
        #expect(try json(frame) == JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))
        #expect(payload != .null)
    }

    @Test("a field the type does not know is ignored")
    func unknownField() throws {
        let user = try decode(
            User.self,
            #"{"id":"0199155c-6200-7b7f-8c11-2a4d3f9e1b70","username":"ada","displayName":"Ada","avatarUrl":null,"later":{"a":1}}"#
        )
        #expect(user.username == "ada")
    }

    // MARK: What the contract promises

    @Test("a required field that is missing is an error that names it")
    func missingRequired() throws {
        #expect(throws: DecodingError.self) {
            _ = try decode(
                User.self, #"{"id":"0199155c-6200-7b7f-8c11-2a4d3f9e1b70","username":"ada","avatarUrl":null}"#)
        }
    }

    @Test("a required field that may be null must still be there: its absence is the contract drifting")
    func requiredNullableMustBePresent() throws {
        #expect(throws: DecodingError.self) {
            _ = try decode(
                User.self, #"{"id":"0199155c-6200-7b7f-8c11-2a4d3f9e1b70","username":"ada","displayName":"Ada"}"#)
        }
        let user = try decode(
            User.self,
            #"{"id":"0199155c-6200-7b7f-8c11-2a4d3f9e1b70","username":"ada","displayName":"Ada","avatarUrl":null}"#)
        #expect(user.avatarUrl == nil)
        // And it is written as `null`, the way the server wrote it.
        guard case .object(let object) = try json(user) else {
            Issue.record("a user is an object")
            return
        }
        #expect(object["avatarUrl"] == .null)
    }

    @Test("a fixed tag that is something else is refused")
    func wrongTag() throws {
        #expect(throws: DecodingError.self) {
            _ = try decode(
                AckFrame.self, #"{"event":"PONG","data":{"id":"0199155c-6200-7b7f-8c11-2a4d3f9e1b70"},"ts":1}"#)
        }
    }

    @Test("three frames share the ACK tag and are told apart by what they hold")
    func ackFrames() throws {
        let id = "0199155c-6200-7b7f-8c11-2a4d3f9e1b70"
        guard case .ack(.ack) = try decode(ServerFrame.self, #"{"event":"ACK","data":{"id":"\#(id)"},"ts":1}"#) else {
            Issue.record("a message acknowledgement was read as another frame")
            return
        }
        guard case .ack(.subscribed) = try decode(ServerFrame.self, #"{"event":"ACK","data":{"channels":[]},"ts":1}"#)
        else {
            Issue.record("a subscription acknowledgement was read as another frame")
            return
        }
        guard
            case .ack(.unsubscribed) = try decode(
                ServerFrame.self, #"{"event":"ACK","data":{"channelIds":["\#(id)"]},"ts":1}"#)
        else {
            Issue.record("an unsubscription acknowledgement was read as another frame")
            return
        }
        #expect(throws: DecodingError.self) {
            _ = try decode(ServerFrame.self, #"{"event":"ACK","data":{"other":1},"ts":1}"#)
        }
    }

    // MARK: How ids and times are held

    @Test("an id read in upper case is written in lower case")
    func idCase() throws {
        let user = try decode(
            User.self,
            #"{"id":"0199155C-6200-7B7F-8C11-2A4D3F9E1B70","username":"a","displayName":"A","avatarUrl":null}"#)
        guard case .object(let object) = try json(user) else { return }
        #expect(object["id"] == .string("0199155c-6200-7b7f-8c11-2a4d3f9e1b70"))
    }

    // MARK: The tables

    @Test("every error code the client knows has the status the server answers it with")
    func errorStatuses() {
        for code in ErrorCode.known {
            #expect(ErrorStatus.all[code.rawValue] != nil, "\(code.rawValue) has no status")
        }
        #expect(ErrorStatus.all["CLIENT_TOO_OLD"] == 426)
        #expect(CloseCode.sessionEnded == 4401)
    }

    @Test("the constants are the contract's")
    func constants() {
        #expect(ContractConstants.contractVersion == 1)
        #expect(ContractConstants.ackDeadlineMs == 3_000)
        #expect(ContractConstants.pageLimit.default == 50)
        #expect(ContractConstants.pageLimit.max == 100)
        #expect(ContractConstants.nativeRedirect == "purlay://auth")
        #expect(ContractConstants.replayRetryDelaysMs == [1_000, 2_000, 4_000])
        #expect(ContractConstants.needsYou.contains("mention"))
    }

    @Test("every route names schemas that exist, and no two routes share an id")
    func endpoints() {
        var ids = Set<String>()
        for endpoint in Endpoints.all {
            #expect(ids.insert(endpoint.id).inserted, "two routes are called \(endpoint.id)")
            #expect(endpoint.path.hasPrefix("/"))
            var names: [String] = []
            if let query = endpoint.query { names.append(query) }
            if case .schema(let name)? = endpoint.body { names.append(name) }
            for case .schema(let name) in endpoint.responses.values { names.append(name) }
            for name in names {
                #expect(ContractRegistry.roundTrips[name] != nil, "\(endpoint.id) names \(name), which has no type")
            }
        }
        #expect(Endpoints.all.count > 50)
    }
}
