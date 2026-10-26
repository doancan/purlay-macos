import PurlayContract

/// The replies of one thread, as the panel shows them: oldest first, each once. A root is in the feed; its replies are not, so they
/// are held here, read a page at a time and added to as live ones come.
public struct ThreadWindow: Equatable, Sendable {
    /// What a thread holds at most. A thread longer than this keeps its newest replies: the panel is for reading what was just said.
    public static let repliesMax = 1_000

    public let root: Uuid
    public let channel: Uuid
    public private(set) var replies: [Message] = []
    /// Where the next page of older-to-newer replies begins, or nil when the last page was read.
    public private(set) var nextCursor: Uuid?
    public private(set) var isLoaded = false

    public init(root: Uuid, channel: Uuid) {
        self.root = root
        self.channel = channel
    }

    /// The first page, in place of what was held. A live reply that arrived while it was on its way is kept: the page may not have had it.
    public mutating func load(_ page: [Message], next: Uuid?) {
        let live = isLoaded ? [] : replies
        replies = []
        insert(page)
        insert(live)
        nextCursor = next
        isLoaded = true
    }

    /// A later page, after what is held.
    public mutating func append(_ page: [Message], next: Uuid?) {
        let held = Set(replies.map(\.id))
        insert(page.filter { !held.contains($0.id) })
        nextCursor = next
    }

    /// A live reply: put where its id says, once, and only if it belongs to this thread. Returns whether anything was added.
    @discardableResult
    public mutating func receive(_ reply: Message) -> Bool {
        guard reply.parentId == root, !replies.contains(where: { $0.id == reply.id }) else { return false }
        insert([reply])
        return true
    }

    @discardableResult
    public mutating func update(_ id: Uuid, _ edit: (inout Message) -> Void) -> Bool {
        guard let at = replies.firstIndex(where: { $0.id == id }) else { return false }
        edit(&replies[at])
        return true
    }

    private mutating func insert(_ messages: [Message]) {
        var held = Set(replies.map(\.id))
        for message in messages where message.parentId == root && held.insert(message.id).inserted {
            replies.append(message)
        }
        replies.sort { $0.id < $1.id }
        if replies.count > Self.repliesMax { replies.removeFirst(replies.count - Self.repliesMax) }
    }
}
