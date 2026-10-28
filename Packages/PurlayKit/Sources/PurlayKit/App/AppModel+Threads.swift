import Foundation
import PurlayContract

extension AppModel {
    // MARK: Threads

    /// A thread of more replies than this many pages is read to here, and its newest replies arrive live.
    private static let threadPagesMax = 50

    /// The root of the open thread as the feed holds it now, so a resolution or an edit is seen; the one it was opened with if the feed
    /// has moved on from it.
    public var threadRoot: Message? {
        guard let thread else { return nil }
        return chat.windows[thread.channel]?.messages.first { $0.id == thread.root } ?? threadRootCopy
    }

    public var threadPending: [PendingMessage] {
        guard let thread else { return [] }
        return pending.filter { $0.parentID == thread.root }
    }

    /// Opens a thread in the panel, or reads the open one again. The answer of a thread that was left for another is not used.
    public func openThread(_ root: Message) async {
        guard let api else { return }
        threadGeneration += 1
        let generation = threadGeneration
        if thread?.root != root.id {
            thread = ThreadWindow(root: root.id, channel: root.channelId)
            threadFollow = .reading
        }
        threadRootCopy = root
        let size = ContractConstants.pageLimit.default
        do {
            var page = try await api.getThread(messageId: root.id.value, query: PageQuery(limit: size))
            guard generation == threadGeneration else { return }
            var replies = page.data
            var next = page.nextCursor
            var pages = 1
            while let cursor = next, pages < Self.threadPagesMax {
                page = try await api.getThread(messageId: root.id.value, query: PageQuery(after: cursor, limit: size))
                guard generation == threadGeneration else { return }
                replies += page.data
                next = page.nextCursor
                pages += 1
            }
            thread?.load(replies, next: next)
            markThreadReadIfSeen()
        } catch {
            guard generation == threadGeneration else { return }
            say(.threadFailed)
        }
        if case .known = threadFollow { return }
        await readFollow(root.id, generation: generation)
    }

    public func closeThread() {
        threadGeneration += 1
        thread = nil
        threadRootCopy = nil
        threadFollow = .reading
    }

    private func readFollow(_ root: Uuid, generation: Int) async {
        guard let api else { return }
        do {
            let answer = try await api.getThreadFollow(messageId: root.value)
            guard generation == threadGeneration else { return }
            threadFollow = .known(answer.following)
        } catch {
            guard generation == threadGeneration else { return }
            threadFollow = .failed
        }
    }

    func reloadThread() async {
        if let root = threadRoot { await openThread(root) }
    }

    /// A reply arrived: the open thread, if it is that one, adds it.
    func receiveReply(_ reply: Message) {
        for window in liveConversationWindows { window.receiveReply(reply) }
        guard thread?.receive(reply) == true else { return }
        markThreadReadIfSeen()
    }

    /// Answers the open thread, with its words and its own files. Nothing is sent that the server would refuse for its length, with a file
    /// not yet gone, with nothing in it, or with no thread to answer.
    @discardableResult
    public func sendReply(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let thread, engine != nil, canSend(text: text, channel: thread.channel, parent: thread.root) else {
            return false
        }
        guard words.count <= ContractConstants.messageContentMax else {
            say(.sendTooLong)
            return false
        }
        submit(words, Place(channel: thread.channel, parent: thread.root))
        return true
    }

    /// The newest reply seen is told to the server, once: only while the window is in front, and not again until there is a newer one.
    func markThreadReadIfSeen() {
        guard isActive, let api, let thread, thread.isLoaded, let newest = thread.replies.last?.id,
            threadMarked[thread.root] != newest
        else { return }
        let root = thread.root
        let before = threadMarked[root]
        threadMarked[root] = newest
        Task { @MainActor in
            do {
                try await api.markThreadRead(messageId: root.value, body: ReadThreadRequest(lastReadMessageId: newest))
            } catch {
                if threadMarked[root] == newest { threadMarked[root] = before }
            }
        }
    }

    @discardableResult
    public func resolveThread() async -> Bool { await changeResolution(resolved: true) }

    @discardableResult
    public func reopenThread() async -> Bool { await changeResolution(resolved: false) }

    private func changeResolution(resolved: Bool) async -> Bool {
        guard let api, let thread else { return false }
        do {
            let updated =
                resolved
                ? try await api.resolveThread(messageId: thread.root.value)
                : try await api.reopenThread(messageId: thread.root.value)
            engine?.revise(thread.root, in: thread.channel) { $0.thread = updated.thread }
            threadRootCopy?.thread = updated.thread
            sync()
            return true
        } catch {
            say(.resolveFailed)
            return false
        }
    }

    /// Follows or lets go of the open thread: painted at once, put back with a word if the server refuses.
    public func setFollowing(_ following: Bool) async {
        guard let api, let thread else { return }
        let generation = threadGeneration
        let before = threadFollow
        if case .known = before { threadFollow = .known(following) }
        do {
            let answer = try await api.setThreadFollow(
                messageId: thread.root.value, body: SetThreadFollowRequest(following: following))
            guard generation == threadGeneration else { return }
            threadFollow = .known(answer.following)
        } catch {
            guard generation == threadGeneration else { return }
            threadFollow = before
            say(.followFailed)
        }
    }
}
