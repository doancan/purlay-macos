import Foundation
import PurlayContract

/// A message sent and not yet known to have arrived, as it is kept between runs. The web's `StoredMessage`, with the same bounds.
public struct StoredMessage: Codable, Sendable, Equatable {
    public let id: Uuid
    public let channelID: Uuid
    public let parentID: Uuid?
    public let content: String
    public let createdAt: Timestamp
    /// What it carries, already uploaded: the outbox holds attachments, never paths.
    public let attachments: [Attachment]

    public init(
        id: Uuid, channelID: Uuid, parentID: Uuid?, content: String, createdAt: Timestamp,
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.channelID = channelID
        self.parentID = parentID
        self.content = content
        self.createdAt = createdAt
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case id, content, createdAt, attachments
        case channelID = "channelId"
        case parentID = "parentId"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Uuid.self, forKey: .id)
        channelID = try container.decode(Uuid.self, forKey: .channelID)
        parentID = try container.decodeIfPresent(Uuid.self, forKey: .parentID)
        content = try container.decode(String.self, forKey: .content)
        createdAt = try container.decode(Timestamp.self, forKey: .createdAt)
        // What an older write kept carried nothing.
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
    }
}

/// What reading the outbox found.
public struct OutboxLoad: Sendable, Equatable {
    /// What was kept, newest last, each a message that can be sent again.
    public let messages: [StoredMessage]
    /// Entries that were there and could not be trusted: not the shape, no words and nothing attached. Said once, never silent.
    public let unrestorable: Int
    /// Where a file that could not be read at all was moved, so nothing is lost without a trace.
    public let corruptFile: URL?

    public static let empty = OutboxLoad(messages: [], unrestorable: 0, corruptFile: nil)
}

public protocol OutboxStore: Sendable {
    func load() -> OutboxLoad
    /// Keeps the newest that fit; an empty list leaves nothing behind. Throws what could not be written: the send itself is
    /// unaffected, and the person is told once that it will not be remembered.
    func save(_ messages: [StoredMessage]) throws
}

/// The outbox as a file in the app's container, one per person (§10): `outbox/<userId>.json`, written atomically on every change,
/// readable by the owner alone.
public struct FileOutboxStore: OutboxStore {
    public static var maximumMessages: Int { ContractConstants.outboxMaxMessages }
    public static var maximumCharacters: Int { ContractConstants.outboxMaxChars }

    private let file: URL
    private let directory: URL
    private let now: @Sendable () -> Date

    /// `userID` becomes part of a file name, so it must be one: a person's id is a UUID, and anything else is refused.
    public init?(base: URL, userID: String, now: @escaping @Sendable () -> Date = Date.init) {
        guard Uuid(userID) != nil else { return nil }
        directory = base.appendingPathComponent("outbox", isDirectory: true)
        file = directory.appendingPathComponent("\(userID).json")
        self.now = now
    }

    public func load() -> OutboxLoad {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return .empty }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return OutboxLoad(messages: [], unrestorable: 0, corruptFile: moveAside())
        }
        guard let entries = try? JSONDecoder().decode([JSONValue].self, from: data) else {
            return OutboxLoad(messages: [], unrestorable: 0, corruptFile: moveAside())
        }
        var messages: [StoredMessage] = []
        var unrestorable = 0
        for entry in entries {
            guard let encoded = try? JSONEncoder().encode(entry),
                let message = try? JSONDecoder().decode(StoredMessage.self, from: encoded), Self.isTrustworthy(message)
            else {
                unrestorable += 1
                continue
            }
            messages.append(message)
        }
        let kept = Array(messages.suffix(Self.maximumMessages))
        return OutboxLoad(messages: kept, unrestorable: unrestorable + (messages.count - kept.count), corruptFile: nil)
    }

    /// A message id of the shape the server accepts, and words or something attached: no words is a message only beside a file.
    static func isTrustworthy(_ message: StoredMessage) -> Bool {
        MessageID.isShape(message.id.value) && (!message.content.isEmpty || !message.attachments.isEmpty)
    }

    public func save(_ messages: [StoredMessage]) throws {
        var kept: [StoredMessage] = []
        var characters = 0
        for message in messages.reversed() {
            characters += message.content.count
            if kept.count >= Self.maximumMessages || characters > Self.maximumCharacters { break }
            kept.insert(message, at: 0)
        }
        let manager = FileManager.default
        if kept.isEmpty {
            try? manager.removeItem(at: file)
            return
        }
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(kept)
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func moveAside() -> URL? {
        let stamp = Int(now().timeIntervalSince1970)
        let aside = file.deletingPathExtension().appendingPathExtension("corrupt-\(stamp)")
        do {
            try FileManager.default.moveItem(at: file, to: aside)
            return aside
        } catch {
            return nil
        }
    }
}
