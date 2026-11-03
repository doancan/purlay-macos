import Foundation
import PurlayContract

/// Which open topics the page lists (D-204): all of them, the questions nobody has answered yet, or those given to the person.
public enum UnresolvedFilter: Hashable, Sendable, CaseIterable {
    case all
    case unanswered
    case assignedToMe
}

/// How a write of a thread's question or decision ended.
public enum KnowledgeWrite: Hashable, Sendable {
    case saved
    /// Somebody else changed it first: what they wrote was read again, and nothing was written over it.
    case conflict
    case failed
}

extension AppModel {
    // MARK: Questions and decisions (D-204)

    /// The root as the app holds it now — the feed's row, else the open thread's copy, else the one handed over — so a write starts
    /// from the newest version the app has seen.
    func freshest(_ root: Message) -> Message {
        if let held = chat.windows[root.channelId]?.messages.first(where: { $0.id == root.id }) { return held }
        if thread?.root == root.id, let copy = threadRootCopy { return copy }
        return root
    }

    /// What a write of a root's knowledge starts from: what it has now, or nothing yet at version 0.
    static func knowledgeRequest(_ root: Message) -> SetKnowledgeRequest {
        let kept = root.thread?.knowledge
        return SetKnowledgeRequest(
            acceptedAnswerId: kept?.acceptedAnswer?.id, assigneeId: kept?.assigneeId,
            decisionNote: kept?.decisionNote ?? "", decisionUrl: kept?.decisionUrl,
            isQuestion: kept?.isQuestion ?? false,
            version: kept?.version ?? 0)
    }

    /// Changes what a root says about itself: whether it is a question, who owns it, the reply that answers it, and its decision.
    /// The write carries the version it was read at; when somebody else changed it first the server refuses it, the root is read
    /// again, and the person is told to look before trying again (nothing of theirs is written over another's).
    @discardableResult
    public func changeKnowledge(of root: Message, _ change: (inout SetKnowledgeRequest) -> Void) async -> KnowledgeWrite
    {
        guard let api, root.parentId == nil, root.deletedAt == nil, !knowledgeSaving.contains(root.id) else {
            return .failed
        }
        let current = freshest(root)
        var request = Self.knowledgeRequest(current)
        change(&request)
        // Only a question has an owner (D-204), as the web client keeps it.
        if !request.isQuestion { request.assigneeId = nil }
        guard request != Self.knowledgeRequest(current) else { return .saved }
        let context = contextGeneration
        knowledgeSaving.insert(root.id)
        defer { if context == contextGeneration { knowledgeSaving.remove(root.id) } }
        do {
            let updated = try await api.setKnowledge(messageId: root.id.value, body: request)
            guard context == contextGeneration else { return .failed }
            adopt(updated)
            return .saved
        } catch let error as APIError where error.code == .knowledgeConflict {
            guard context == contextGeneration else { return .failed }
            say(.knowledgeConflict)
            await rereadRoot(root)
            return .conflict
        } catch {
            guard context == contextGeneration else { return .failed }
            say(.knowledgeFailed)
            return .failed
        }
    }

    /// Marks a root as a question, or no longer one.
    @discardableResult
    public func setQuestion(_ question: Bool, on root: Message) async -> KnowledgeWrite {
        await changeKnowledge(of: root) { $0.isQuestion = question }
    }

    /// Chooses a reply as the answer of its thread, or none. Answering is not resolving: the two stay separate acts (D-204).
    @discardableResult
    public func acceptAnswer(_ reply: Message?, for root: Message) async -> KnowledgeWrite {
        if let reply, reply.parentId != root.id || reply.deletedAt != nil { return .failed }
        return await changeKnowledge(of: root) { $0.acceptedAnswerId = reply?.id }
    }

    /// Gives a question to a member of its channel, or to nobody. Nobody is told (D-204).
    @discardableResult
    public func assignQuestion(to person: Uuid?, on root: Message) async -> KnowledgeWrite {
        await changeKnowledge(of: root) {
            $0.isQuestion = true
            $0.assigneeId = person
        }
    }

    /// The decision a thread came to, in a few plain words, and where it is written up. Both empty clears them.
    @discardableResult
    public func setDecision(note: String, url: String, on root: Message) async -> KnowledgeWrite {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return await changeKnowledge(of: root) {
            $0.decisionNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            $0.decisionUrl = link.isEmpty ? nil : link
        }
    }

    /// Whether a reply is the open thread's accepted answer.
    public func isAcceptedAnswer(_ reply: Message) -> Bool {
        guard let root = threadRoot, reply.parentId == root.id else { return false }
        return root.thread?.knowledge?.acceptedAnswer?.id == reply.id
    }

    /// The person a question was given to, by name where the app knows them.
    public func person(_ id: Uuid) -> User? {
        if let thread, let found = channelPeople[thread.channel]?.first(where: { $0.id == id }) { return found }
        return workspacePeople.first { $0.id == id } ?? chat.channels.values.lazy.flatMap(\.peers).first { $0.id == id }
    }

    /// Who a question in a channel can be given to: its members, as the server lists them now. Nil when that could not be read.
    public func questionOwners(in channel: Uuid) async -> [User]? {
        guard let api else { return nil }
        let context = contextGeneration
        guard let members = try? await api.listChannelMembers(channelId: channel.value), context == contextGeneration
        else { return nil }
        let people = members.map(\.user)
        channelPeople[channel] = people
        return people.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// A root the server answered with: the feed, the open thread and the open topics hold it from now on.
    func adopt(_ updated: Message) {
        let root = chat.personalProjection(updated)
        engine?.revise(root.id, in: root.channelId) { $0.thread = root.thread }
        if thread?.root == root.id { threadRootCopy = root }
        if let at = unresolvedItems.firstIndex(where: { $0.id == root.id }) { unresolvedItems[at] = root }
        sync()
    }

    /// Reads a root again, after the server said the app's copy is old.
    private func rereadRoot(_ root: Message) async {
        guard let api else { return }
        let context = contextGeneration
        guard let fresh = try? await api.getMessage(messageId: root.id.value), context == contextGeneration else {
            return
        }
        adopt(fresh)
    }

    // MARK: Open topics, filtered

    public func setUnresolvedFilter(_ filter: UnresolvedFilter) async {
        unresolvedFilter = filter
        await loadUnresolved()
    }

    /// The query the open topics page asks with, for a page after `before`.
    func unresolvedQuery(before: Uuid? = nil) -> UnresolvedQuery {
        UnresolvedQuery(
            assigneeId: unresolvedFilter == .assignedToMe ? me?.user.id : nil, before: before,
            channelId: unresolvedChannelID, limit: ContractConstants.pageLimit.default,
            unanswered: unresolvedFilter == .unanswered ? .yes : nil)
    }
}

extension Message {
    /// What a thread's state is, as a question: nil when the root is not one.
    public var questionState: QuestionState? {
        guard deletedAt == nil, let knowledge = thread?.knowledge, knowledge.isQuestion else { return nil }
        return knowledge.acceptedAnswer == nil ? .unanswered : .answered
    }

    /// The name a message was posted under when nobody wrote it: an incoming webhook's (D-245). Nil for a person's message and for
    /// a repository's event.
    public var webhookName: String? {
        guard sender == nil, githubEvent == nil else { return nil }
        return incomingWebhook?.name
    }
}

public enum QuestionState: Hashable, Sendable {
    case unanswered
    case answered
}
