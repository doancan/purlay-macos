import Foundation
import PurlayContract

extension AppModel {
    // MARK: Link previews (D-293)

    /// The card for the first link of a message that has one, or nil: a message with no link, one that is gone, a link the server
    /// will not fetch and a server that cannot answer are all no card, and no word about it. Asked once for each message and link in
    /// this session, since the server caches what it fetched and the card would not change under the person's eyes.
    public func linkPreview(for message: Message) async -> LinkPreviewCard? {
        guard let api, message.deletedAt == nil, message.hiddenForMe != true, !isPersonallyDeleted(message.id) else {
            return nil
        }
        let context = contextGeneration
        for url in LinkCandidates.urls(in: message.content, excluding: origin?.origin) {
            let key = "\(message.id.value)|\(url.absoluteString)"
            if let known = linkPreviews[key] {
                if let known { return known }
                continue
            }
            // A failure is not asked about again for a while: scrolling past it must not become a request each time.
            if let failed = linkPreviewFailures[key], Date().timeIntervalSince(failed) < Self.linkPreviewRetryAfter {
                continue
            }
            let card: LinkPreviewCard?
            do {
                let answer = try await api.previewMessageLink(
                    messageId: message.id.value, body: WebLinkPreviewRequest(url: url.absoluteString))
                card = answer.flatMap { preview in
                    LinkPreviewCard(
                        url: url, title: preview.title, summary: preview.description,
                        imageURL: preview.imageUrl.flatMap { URL(string: $0) }.flatMap(ownImage))
                }
            } catch {
                linkPreviewFailures[key] = Date()
                continue
            }
            guard context == contextGeneration else { return nil }
            linkPreviews[key] = .some(card)
            if let card { return card }
        }
        return nil
    }

    /// How long a link that could not be asked about is left alone.
    static let linkPreviewRetryAfter: TimeInterval = 60

    /// The card's picture, only from this server: it is the one that fetched the page and proxies its image, so a page cannot have
    /// every reader's Mac ask its own host for a picture, which would tell it who read the message and when.
    private func ownImage(_ url: URL) -> URL? {
        guard url.scheme == "https", let own = origin?.origin,
            url.host(percentEncoded: false) == own.host(percentEncoded: false)
        else { return nil }
        return url
    }
}
