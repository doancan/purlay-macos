import Foundation
import PurlayContract

/// The pages that stay in the browser (§2 non-goals: administration, invitations, profile), and the address of a channel or a
/// message there. Built from the server's own `appUrl` and the workspace's slug, never from what a message says.
public enum WebPage: Hashable, Sendable {
    case profile
    case account
    case preferences
    case members
    case invitations
    case workspace
    case integrations
    case server
    case audit
    case data
    case channel(Uuid)
    case message(Uuid, in: Uuid)

    /// The path under the workspace, as the web client routes it.
    var path: String {
        switch self {
        case .profile: "settings/profile"
        case .account: "settings/account"
        case .preferences: "settings/preferences"
        case .members: "settings/members"
        case .invitations: "settings/invitations"
        case .workspace: "settings/general"
        case .integrations: "settings/integrations"
        case .server: "settings/server"
        case .audit: "settings/audit"
        case .data: "settings/data"
        case .channel(let id): "c/\(id.value)"
        case .message(_, let channel): "c/\(channel.value)"
        }
    }

    var query: [URLQueryItem] {
        if case .message(let id, _) = self { return [URLQueryItem(name: "message", value: id.value)] }
        return []
    }
}

extension AppModel {
    // MARK: The web

    /// Where a page is in the browser, or nil before the app knows its server and workspace.
    public func webURL(_ page: WebPage) -> URL? {
        guard let origin, let slug = workspace?.slug,
            var components = URLComponents(url: origin.origin, resolvingAgainstBaseURL: false)
        else { return nil }
        // The slug is the server's and URL-safe by its rules; it is still encoded as a path segment, never trusted as one.
        let segment = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? slug
        components.percentEncodedPath = "/w/\(segment)/\(page.path)"
        components.queryItems = page.query.isEmpty ? nil : page.query
        return components.url
    }
}
