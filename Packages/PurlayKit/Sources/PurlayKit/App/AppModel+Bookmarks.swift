import Foundation
import PurlayContract

/// What a person types for a bookmark, made into what the contract holds (D-218): a web address with its scheme, `docs.example.com`
/// read as `https://docs.example.com` as an address bar reads it, and a name, the site's own when none is given. The server stays the
/// authority on both; this only keeps from asking what it would certainly refuse.
public enum BookmarkAddress {
    /// The address as it will be sent, or nil when it is not a web address.
    public static func url(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        // A scheme written out (`mailto:`, `javascript:`) is left as typed, for the check below to refuse.
        let written = hasScheme(trimmed) ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: written),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        // `HTTPS://` is the same address; the contract's pattern spells the scheme in lowercase.
        return scheme + written.dropFirst(scheme.count)
    }

    /// The name given, or the site's own (`docs.example.com`) when it was left empty.
    public static func title(_ typed: String, for url: String) -> String {
        let given = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard given.isEmpty else { return given }
        let host = URLComponents(string: url)?.host ?? url
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Whether the text names its scheme. `example.com:8080` and `localhost:8080` name a host and its port, not a scheme.
    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":"), text.first?.isLetter == true else { return false }
        let scheme = text[..<colon]
        guard scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return false }
        if text[colon...].hasPrefix("://") { return true }
        return !scheme.contains(".") && text[text.index(after: colon)...].first?.isNumber != true
    }
}

extension AppModel {
    // MARK: Bookmarks

    public enum BookmarkOutcome: Equatable, Sendable {
        case added
        /// Not a web address, or a name or address the server would not keep.
        case invalid
        /// The channel holds as many as it may.
        case full
        case failed
    }

    /// The links kept under the open channel's header.
    public var channelBookmarks: [ChannelBookmark] { selectedChannel.flatMap { bookmarks[$0] } ?? [] }

    public func bookmarks(in channel: Uuid) -> [ChannelBookmark] { bookmarks[channel] ?? [] }

    /// Whoever can see a channel reads its bookmarks; its members change them (D-218).
    public func canChangeBookmarks(in channel: Uuid) -> Bool { chat.channels[channel]?.state != nil }

    @discardableResult
    func reloadBookmarks(_ channel: Uuid) async -> Bool {
        guard let api else { return true }
        let session = contextGeneration
        guard let list = try? await api.listBookmarks(channelId: channel.value) else { return false }
        guard session == contextGeneration else { return true }
        bookmarks[channel] = list
        return true
    }

    /// Asked again when the person asks, as the pinned sheet does.
    public func refreshBookmarks() async -> Bool {
        guard let selectedChannel else { return true }
        return await reloadBookmarks(selectedChannel)
    }

    /// Adds a link to a channel. Held only once the server made it: the same address again is the bookmark already there.
    public func addBookmark(title: String, address: String, in channel: Uuid) async -> BookmarkOutcome {
        guard let api else { return .failed }
        guard let url = BookmarkAddress.url(address) else { return .invalid }
        let session = contextGeneration
        do {
            let made = try await api.addBookmark(
                channelId: channel.value,
                body: AddBookmarkRequest(title: BookmarkAddress.title(title, for: url), url: url))
            guard session == contextGeneration else { return .failed }
            var list = bookmarks[channel] ?? []
            if !list.contains(where: { $0.id == made.id }) { list.append(made) }
            bookmarks[channel] = list
            return .added
        } catch let error as APIError {
            switch error.code {
            case .bookmarksLimit: return .full
            case .validationFailed: return .invalid
            default: return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Takes a link off its channel: gone at once, put back as the server has it with a word if refused. One the server no longer
    /// has is gone already.
    public func removeBookmark(_ bookmark: ChannelBookmark) async {
        guard let api else { return }
        let session = contextGeneration
        let channel = bookmark.channelId
        bookmarks[channel] = (bookmarks[channel] ?? []).filter { $0.id != bookmark.id }
        do {
            try await api.removeBookmark(channelId: channel.value, bookmarkId: bookmark.id.value)
        } catch let error as APIError where error.code == .bookmarkNotFound {
            return
        } catch {
            guard session == contextGeneration else { return }
            if await reloadBookmarks(channel) == false, session == contextGeneration {
                var list = bookmarks[channel] ?? []
                if !list.contains(where: { $0.id == bookmark.id }) {
                    list.append(bookmark)
                    list.sort { $0.addedAt.date < $1.addedAt.date }
                }
                bookmarks[channel] = list
            }
            if session == contextGeneration { say(.bookmarkFailed) }
        }
    }
}
