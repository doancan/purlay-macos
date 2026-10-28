import Foundation
import PurlayContract

/// A web permalink, optionally wrapped in the registered app scheme. Authentication callbacks are a separate route.
public struct ConversationLink: Equatable, Sendable {
    public let server: ServerAddress
    public let workspaceSlug: String
    public let channel: Uuid
    public let message: Uuid?

    public static func parse(_ url: URL, allowsLocalHTTP: Bool = false) -> ConversationLink? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if parts.scheme?.lowercased() == "purlay" {
            guard parts.host == "open", parts.user == nil, parts.password == nil, parts.port == nil,
                parts.path.isEmpty || parts.path == "/", parts.fragment == nil,
                let query = parts.queryItems, query.count == 1, query[0].name == "url",
                let value = query[0].value, let web = URLComponents(string: value)
            else { return nil }
            parts = web
        }
        guard parts.fragment == nil, parts.user == nil, parts.password == nil else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 5, path[0].isEmpty, path[1] == "w", path[3] == "c",
            let slug = String(path[2]).removingPercentEncoding, !slug.isEmpty, slug.count <= 100,
            slug.rangeOfCharacter(
                from: .whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "/\\?#")))
                == nil,
            let channelText = String(path[4]).removingPercentEncoding, let channel = Uuid(channelText)
        else { return nil }
        let query = parts.queryItems ?? []
        guard query.count <= 1, query.allSatisfy({ $0.name == "message" }) else { return nil }
        let message = query.first?.value.flatMap(Uuid.init)
        guard query.isEmpty || message != nil else { return nil }
        parts.path = ""
        parts.query = nil
        guard let origin = parts.string, let server = try? ServerAddress.parse(origin, allowsLocalHTTP: allowsLocalHTTP)
        else { return nil }
        return ConversationLink(server: server, workspaceSlug: slug, channel: channel, message: message)
    }

    public static func appURL(for webURL: URL) -> URL? {
        var parts = URLComponents()
        parts.scheme = "purlay"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "url", value: webURL.absoluteString)]
        return parts.url
    }
}

extension AppModel {
    public func appURL(_ page: WebPage) -> URL? {
        switch page {
        case .channel, .message: webURL(page).flatMap(ConversationLink.appURL)
        default: nil
        }
    }

    func openConversationLink(_ link: ConversationLink) async -> Bool {
        guard phase == .ready, workspace?.slug == link.workspaceSlug,
            origin == link.server || server == link.server,
            let channel = chat.channels[link.channel], channel.workspaceId == workspace?.id
        else { return false }
        if let message = link.message { return await revealMessage(message, in: channel.id) }
        await showChannel(channel.id)
        return phase == .ready
    }
}
