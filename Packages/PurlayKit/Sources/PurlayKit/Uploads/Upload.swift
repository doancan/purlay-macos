import Foundation
import PurlayContract

/// A file the person chose, read: its name and its bytes. Nothing here is a path: what was read is what is sent.
public struct PickedFile: Sendable, Equatable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Why a file did not go, in a form a screen turns into words (D-159): from what the server answered, never its own English.
public enum UploadFailure: Equatable, Sendable {
    case empty
    case tooLarge
    case imageTooLarge
    case imageUnreadable
    case unsupported
    case storageFull(remainingBytes: Int)
    case tooManyWaiting
    case noConnection
    case busy
    case storageUnavailable
    case sessionEnded
    case noAccess
    case unknown

    /// Retry is there when trying again can be answered differently. Remove is always there.
    public var canRetry: Bool {
        switch self {
        case .noConnection, .busy, .storageUnavailable, .tooManyWaiting, .unknown: true
        case .empty, .tooLarge, .imageTooLarge, .imageUnreadable, .unsupported, .storageFull, .sessionEnded, .noAccess:
            false
        }
    }

    public static func from(_ error: any Error) -> UploadFailure {
        if let api = error as? APIError {
            switch api.code {
            case .payloadTooLarge: return .tooLarge
            case .imageTooLarge: return .imageTooLarge
            case .imageUnreadable: return .imageUnreadable
            case .unsupportedMediaType: return .unsupported
            case .storageQuotaExceeded:
                if case .object(let details)? = api.details, case .integer(let room)? = details["remainingBytes"] {
                    return .storageFull(remainingBytes: max(0, room))
                }
                return .storageFull(remainingBytes: 0)
            case .tooManyPendingUploads: return .tooManyWaiting
            case .rateLimited: return .busy
            case .storageUnavailable, .databaseUnavailable: return .storageUnavailable
            case .unauthenticated: return .sessionEnded
            case .forbidden, .notAChannelMember, .workspaceNotFound, .channelNotFound: return .noAccess
            default: return .unknown
            }
        }
        if let transport = error as? TransportError {
            switch transport {
            case .offline, .timedOut, .connection, .secureConnectionFailed: return .noConnection
            case .noSession: return .sessionEnded
            default: return .unknown
            }
        }
        return .unknown
    }
}

/// A file on its way to a message: uploaded as soon as it is chosen, so that sending is only linking it.
public struct Upload: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case uploading
        case done(Attachment)
        case failed(UploadFailure)
    }

    public let id: Uuid
    public let name: String
    public let size: Int
    public var state: State

    public var attachment: Attachment? {
        if case .done(let attachment) = state { return attachment }
        return nil
    }

    public var isUploading: Bool { state == .uploading }

    public var hasFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

/// What a file may be before it is sent.
public enum UploadRules {
    /// The longest name the app sends, in bytes: far under what a URL and a database column take.
    public static let nameBytesMax = 200

    /// What is wrong with a file before it is asked of the server, if anything.
    public static func check(name: String, size: Int) -> UploadFailure? {
        if size <= 0 { return .empty }
        if size > ContractConstants.attachmentBytesMax { return .tooLarge }
        return nil
    }

    /// A name the server will take: trimmed, a path made a name, nothing empty, and cut to length at a character, the extension kept.
    public static func name(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(name.map { $0 == "/" || $0 == "\\" || $0.isNewline ? "_" : $0 })
        if name.isEmpty { return "file" }
        guard name.utf8.count > nameBytesMax else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        let room = nameBytesMax - suffix.utf8.count
        var stem = ""
        for character in name.dropLast(suffix.count) {
            if stem.utf8.count + String(character).utf8.count > room { break }
            stem.append(character)
        }
        return stem + suffix
    }

    /// The name a received file is offered under when saved. It is the sender's, so it may name a place: only its last
    /// component is kept, and nothing in it can hide the file, hide its kind (a directional override turns `gpj.exe` into
    /// what reads as `exe.jpg`) or break a line.
    public static func savingName(_ raw: String) -> String {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = String(String.UnicodeScalarView(last.unicodeScalars.filter { !isHidden($0) && $0 != ":" }))
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        return self.name(name)
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value <= 0x1f || (0x7f...0x9f).contains(value) || (0x200b...0x200f).contains(value)
            || (0x2028...0x202e).contains(value) || (0x2066...0x2069).contains(value) || value == 0xfeff
    }
}
