import Foundation
import PurlayContract

/// Why a saved search could not be written or removed. The view says it in the person's language.
public enum SavedSearchFailure: Error, Equatable, Sendable {
    /// No name, or criteria the server would not keep (no words and no filter, an end before the start).
    case invalid
    /// As many are saved as the server keeps: one has to go first.
    case limit
    /// Gone: removed from another window or device.
    case notFound
    case failed
    case sessionChanged

    static func from(_ error: any Error) -> Self {
        guard let error = error as? APIError else { return .failed }
        switch error.code {
        case .savedSearchLimit: return .limit
        case .savedSearchNotFound, .channelNotFound: return .notFound
        case .validationFailed: return .invalid
        default: return .failed
        }
    }
}

extension AppModel {
    /// The person's named searches in this workspace (D-204): filters, never results, so each run sees what is visible now. Every page
    /// is read, newest first; only the newest read is kept.
    public func loadSavedSearches() async {
        guard let api, let workspace else { return }
        savedSearchGeneration += 1
        let generation = savedSearchGeneration
        let context = contextGeneration
        if savedSearches.isEmpty { savedSearchesStatus = .loading }
        var found: [SavedSearch] = []
        var cursor: Uuid?
        do {
            repeat {
                let page = try await api.listSavedSearches(
                    workspaceId: workspace.id.value,
                    query: OlderPageQuery(before: cursor, limit: ContractConstants.pageLimit.max))
                guard context == contextGeneration, generation == savedSearchGeneration else { return }
                let held = Set(found.map(\.id))
                found += page.data.filter { !held.contains($0.id) }
                // A cursor that does not move would read the same page for ever.
                cursor = page.nextCursor == cursor ? nil : page.nextCursor
            } while cursor != nil
            savedSearches = found.sorted { $0.id > $1.id }
            savedSearchesStatus = .loaded
        } catch {
            guard context == contextGeneration, generation == savedSearchGeneration else { return }
            savedSearchesStatus = .failed
        }
    }

    /// A new id for a search about to be saved. The view keeps it until the save is confirmed, so a retry after a lost answer
    /// replaces the same one rather than saving it twice.
    public func newSavedSearchID() -> Uuid { uploadIDs.next() }

    /// Whether what is asked for now can be saved: what could be searched for, words or a filter.
    public var canSaveSearch: Bool { searchable(searchQuery) && (!searchQuery.isEmpty || searchHasFilters) }

    /// Saves the search as asked for now under a name.
    @discardableResult
    public func saveSearch(id: Uuid, name: String) async throws(SavedSearchFailure) -> SavedSearch {
        guard canSaveSearch else { throw .invalid }
        return try await writeSavedSearch(id: id, name: name, criteria: searchCriteria)
    }

    /// Gives a saved search another name; what it searches for stays.
    @discardableResult
    public func renameSavedSearch(_ saved: SavedSearch, to name: String) async throws(SavedSearchFailure) -> SavedSearch
    {
        try await writeSavedSearch(id: saved.id, name: name, criteria: saved.query)
    }

    public func deleteSavedSearch(_ saved: SavedSearch) async throws(SavedSearchFailure) {
        guard let api, let workspace else { throw .failed }
        let context = contextGeneration
        do {
            try await api.deleteSavedSearch(workspaceId: workspace.id.value, searchId: saved.id.value)
        } catch { throw .from(error) }
        guard context == contextGeneration else { throw .sessionChanged }
        savedSearchGeneration += 1
        savedSearches.removeAll { $0.id == saved.id }
    }

    private func writeSavedSearch(id: Uuid, name: String, criteria: SearchCriteria) async throws(SavedSearchFailure)
        -> SavedSearch
    {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .invalid }
        guard let api, let workspace else { throw .failed }
        let context = contextGeneration
        let saved: SavedSearch
        do {
            saved = try await api.saveSearch(
                workspaceId: workspace.id.value, searchId: id.value,
                body: SaveSearchRequest(name: name, query: criteria))
        } catch {
            if (error as? APIError)?.code == .savedSearchNotFound {
                guard context == contextGeneration else { throw .sessionChanged }
                savedSearches.removeAll { $0.id == id }
            }
            throw .from(error)
        }
        guard context == contextGeneration else { throw .sessionChanged }
        // A read on its way began before this write: it would bring back the list without it.
        savedSearchGeneration += 1
        if savedSearchesStatus != .loaded { savedSearchesStatus = .loaded }
        savedSearches.removeAll { $0.id == saved.id }
        savedSearches.append(saved)
        savedSearches.sort { $0.id > $1.id }
        return saved
    }

    func clearSavedSearches() {
        savedSearchGeneration += 1
        savedSearches = []
        savedSearchesStatus = .idle
    }
}
