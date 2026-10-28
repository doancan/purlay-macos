import Foundation
import PurlayContract

// What the connection needs to read of a frame without knowing which one it is. Each is an exhaustive `switch`: a frame the
// contract gains and this does not handle is a compile error, not a frame that is quietly passed over (§9.5).

extension ServerFrame {
    /// The id of the frame this one answers, if it answers one.
    public var refID: Uuid? {
        switch self {
        case .ack(let ack):
            switch ack {
            case .ack(let frame): return frame.refId
            case .subscribed(let frame): return frame.refId
            case .unsubscribed(let frame): return frame.refId
            }
        case .error(let frame): return frame.refId
        case .messageCreated(let frame): return frame.refId
        case .messageHidden(let frame): return frame.refId
        case .threadUpdated(let frame): return frame.refId
        case .reactionsUpdated(let frame): return frame.refId
        case .messageRevised(let frame): return frame.refId
        case .channelState(let frame): return frame.refId
        case .channelAdded(let frame): return frame.refId
        case .channelUpdated(let frame): return frame.refId
        case .sessionEnded(let frame): return frame.refId
        case .accessRevoked(let frame): return frame.refId
        case .deepWorkUpdated(let frame): return frame.refId
        case .remindersUpdated(let frame): return frame.refId
        case .savedUpdated(let frame): return frame.refId
        case .notificationsUpdated(let frame): return frame.refId
        case .pinsUpdated(let frame): return frame.refId
        case .incidentUpdated(let frame): return frame.refId
        case .messageVersionsUpdated(let frame): return frame.refId
        case .channelsUpdated(let frame): return frame.refId
        case .typing(let frame): return frame.refId
        case .workspaceUpdated(let frame): return frame.refId
        case .presence(let frame): return frame.refId
        case .pong(let frame): return frame.refId
        case .unknown: return nil
        }
    }
}

extension AppErrorBody {
    /// The error code, whichever member the server sent.
    public var code: ErrorCode {
        switch self {
        case .validationFailed: return .validationFailed
        case .lastOwner: return .lastOwner
        case .storageQuotaExceeded: return .storageQuotaExceeded
        case .setupStepRefused: return .setupStepRefused
        case .settingsChangeFailed: return .settingsChangeFailed
        case .serverChangeRefused: return .serverChangeRefused
        case .clientTooOld: return .clientTooOld
        case .other(let other): return ErrorCode(rawValue: other.code.rawValue)
        }
    }
}

/// What one text message from the server is.
public enum ServerMessage: Sendable, Equatable {
    case frame(ServerFrame)
    /// Well formed and an event this client was not built for: a newer server is not a reason to leave it (D-82).
    case unknown(tag: String)
    /// Not a frame this contract could have sent. Guessing at it would fold an unknown into the message list.
    case malformed

    public static func parse(_ text: String) -> ServerMessage {
        guard let frame = try? JSONDecoder().decode(ServerFrame.self, from: Data(text.utf8)) else { return .malformed }
        if case .unknown(let tag, _) = frame { return .unknown(tag: tag) }
        return .frame(frame)
    }
}
