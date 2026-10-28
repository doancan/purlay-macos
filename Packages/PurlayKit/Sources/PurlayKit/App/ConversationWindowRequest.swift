import PurlayContract

/// Identifies a conversation without carrying credentials or message content into scene restoration.
public struct ConversationWindowRequest: Codable, Hashable, Sendable {
    public let server: String
    public let user: Uuid
    public let workspace: Uuid
    public let channel: Uuid
}
