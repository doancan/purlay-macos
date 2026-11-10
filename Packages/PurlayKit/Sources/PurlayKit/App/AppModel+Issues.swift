import Foundation
import PurlayContract

/// Which issues a list shows.
public enum IssueFilter: Sendable, Equatable {
    case open, done

    var status: IssueStatus { self == .open ? .open : .done }
}

extension AppModel {
    // MARK: The issues module (D-254)

    public var issuesHaveMore: Bool { issuesCursor != nil }

    /// The longest title an issue may have, and the longest details: the server's limits.
    static let issueTitleLimit = 200
    static let issueDetailsLimit = 10_000

    public func openIssues() async {
        guard hasModule(.issues) else { return }
        navigationGeneration += 1
        inboxOpen = false
        unresolvedOpen = false
        issuesOpen = true
        closeThread()
        await reloadIssues()
    }

    public func setIssueFilter(_ filter: IssueFilter) async {
        issueFilter = filter
        await reloadIssues()
    }

    public func reloadIssues() async {
        guard let api, let workspace else { return }
        issuesGeneration += 1
        let generation = issuesGeneration
        issuesLoadingMore = false
        issuesStatus = .loading
        issueItems = []
        issuesCursor = nil
        do {
            let page = try await api.listIssues(
                workspaceId: workspace.id.value,
                query: IssueQuery(
                    limit: ContractConstants.pageLimit.default,
                    status: IssueQuery.Status(rawValue: issueFilter.status.rawValue)))
            // An answer to a look the person has since changed or left is not used.
            guard generation == issuesGeneration else { return }
            issueItems = page.data
            issuesCursor = page.nextCursor
            issuesStatus = .loaded
        } catch {
            guard generation == issuesGeneration else { return }
            issuesStatus = .failed
        }
    }

    public func loadMoreIssues() async {
        guard let api, let workspace, let cursor = issuesCursor, issuesStatus == .loaded, !issuesLoadingMore else {
            return
        }
        issuesLoadingMore = true
        let generation = issuesGeneration
        defer { if generation == issuesGeneration { issuesLoadingMore = false } }
        do {
            let page = try await api.listIssues(
                workspaceId: workspace.id.value,
                query: IssueQuery(
                    before: cursor, limit: ContractConstants.pageLimit.default,
                    status: IssueQuery.Status(rawValue: issueFilter.status.rawValue)))
            guard generation == issuesGeneration else { return }
            issueItems += page.data
            issuesCursor = page.nextCursor
        } catch {
            guard generation == issuesGeneration else { return }
            say(.loadFailed)
        }
    }

    /// Makes an issue. False, asking nothing, for an empty or overlong title or overlong details; false when the server refuses.
    public func createIssue(title: String, details: String, assignee: Uuid?) async -> Bool {
        guard let api, let workspace else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= Self.issueTitleLimit, details.count <= Self.issueDetailsLimit else {
            return false
        }
        do {
            let made = try await api.createIssue(
                workspaceId: workspace.id.value,
                body: CreateIssueRequest(
                    assigneeId: assignee.map { .some($0) }, body: details.isEmpty ? nil : details, title: title))
            if issuesOpen, issueFilter == .open { issueItems.insert(made, at: 0) }
            return true
        } catch {
            say(.issueFailed)
            return false
        }
    }

    /// Marks it done or open again: it leaves the list it no longer belongs to at once, and comes back if the server refuses.
    public func setIssueStatus(_ issue: Issue, _ status: IssueStatus) async {
        guard let at = issueItems.firstIndex(where: { $0.id == issue.id }) else { return }
        let context = contextGeneration
        issueItems[at].status = status
        if issueFilter.status != status { issueItems.remove(at: at) }
        await update(
            issue, UpdateIssueRequest(status: UpdateIssueRequest.Status(rawValue: status.rawValue)), context: context)
    }

    /// Gives it to somebody, or to nobody.
    public func assignIssue(_ issue: Issue, to person: Uuid?) async {
        guard let at = issueItems.firstIndex(where: { $0.id == issue.id }) else { return }
        let context = contextGeneration
        issueItems[at].assigneeId = person
        await update(issue, UpdateIssueRequest(assigneeId: .some(person)), context: context)
    }

    public func deleteIssue(_ issue: Issue) async {
        guard let api, let workspace, let at = issueItems.firstIndex(where: { $0.id == issue.id }) else { return }
        let context = contextGeneration
        let position = at
        issueItems.remove(at: at)
        do {
            try await api.deleteIssue(workspaceId: workspace.id.value, issueId: issue.id.value)
        } catch {
            guard context == contextGeneration else { return }
            // Back where it was, and nothing else touched.
            issueItems.insert(issue, at: min(position, issueItems.count))
            say(.issueFailed)
        }
    }

    /// Asks the server for a change already painted. A refusal puts back this issue as it was, and no other.
    private func update(_ issue: Issue, _ change: UpdateIssueRequest, context: Int) async {
        guard let api, let workspace else { return }
        do {
            let saved = try await api.updateIssue(
                workspaceId: workspace.id.value, issueId: issue.id.value, body: change)
            if let at = issueItems.firstIndex(where: { $0.id == saved.id }) { issueItems[at] = saved }
        } catch {
            guard context == contextGeneration else { return }
            if let at = issueItems.firstIndex(where: { $0.id == issue.id }) {
                issueItems[at] = issue
            } else if issueFilter.status == issue.status {
                issueItems.insert(issue, at: 0)
            }
            say(.issueFailed)
        }
    }

    func clearIssues() {
        issuesGeneration += 1
        issuesOpen = false
        issueItems = []
        issuesCursor = nil
        issuesStatus = .idle
        issueFilter = .open
    }
}
