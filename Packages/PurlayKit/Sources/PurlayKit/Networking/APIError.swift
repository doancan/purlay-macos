import Foundation
import PurlayContract

/// The one error shape of the API (`API.md` §1): a status, a code, and words that are not for the person to read.
/// The interface shows its own sentence for each code and never `message` (§5.4).
public struct APIError: Error, Sendable, Equatable {
    public let status: Int
    public let code: ErrorCode
    public let message: String
    /// What the code says more about: validation fields, the version a client must have, a quota. Held as it came.
    public let details: JSONValue?
    /// Seconds to wait, when the server said (`Retry-After` on a `429`).
    public let retryAfter: Int?
    /// The id the request carried, so an operator can find its line in the server's log.
    public let requestID: String?

    public init(
        status: Int, code: ErrorCode, message: String, details: JSONValue? = nil, retryAfter: Int? = nil,
        requestID: String? = nil
    ) {
        self.status = status
        self.code = code
        self.message = message
        self.details = details
        self.retryAfter = retryAfter
        self.requestID = requestID
    }

    /// The code an answer that is not the error shape is given: the status is known and nothing else is.
    public static let unreadableCode = ErrorCode.unknown("UNREADABLE_ERROR")

    private struct Envelope: Decodable {
        struct Body: Decodable {
            let code: ErrorCode
            let message: String
            let details: JSONValue?
        }
        let error: Body
    }

    /// An error answer, read; or the status alone, when the body is not the shape the contract promises.
    static func from(_ response: HTTPResponse, requestID: String?) -> APIError {
        let retryAfter = response.headers["retry-after"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: response.body) {
            return APIError(
                status: response.status, code: envelope.error.code, message: envelope.error.message,
                details: envelope.error.details, retryAfter: retryAfter, requestID: requestID)
        }
        return APIError(
            status: response.status, code: unreadableCode, message: "", retryAfter: retryAfter, requestID: requestID)
    }

    /// For `426`: what the server asks of this client, if it said.
    public var clientTooOld: ClientTooOldDetails? {
        guard code == .clientTooOld, let details,
            let data = try? JSONEncoder().encode(details)
        else { return nil }
        return try? JSONDecoder().decode(ClientTooOldDetails.self, from: data)
    }
}
