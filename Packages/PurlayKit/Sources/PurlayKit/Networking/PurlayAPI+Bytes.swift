import Foundation
import PurlayContract

/// The routes that carry a file's own bytes: the generated client leaves them out, because a body of bytes has no schema to generate from.
extension PurlayAPI {
    /// `POST /api/workspaces/:workspaceId/uploads`: the file as raw bytes under an id of the app's choosing, so that the same upload again
    /// is the same upload. The answer is the attachment, not yet attached to any message.
    public func uploadFile(workspaceId: String, id: Uuid, name: String, bytes: Data) async throws -> Attachment {
        try await client.sendBytes(
            Endpoints.uploadFile, path: ["workspaceId": workspaceId], query: UploadQuery(id: id, name: name),
            bytes: bytes, idempotent: true,
            as: Attachment.self)
    }

    /// `GET /api/attachments/:attachmentId`: what was uploaded, as the server brokers it.
    public func downloadAttachment(attachmentId: String) async throws -> Data {
        try await client.sendForData(Endpoints.downloadAttachment, path: ["attachmentId": attachmentId])
    }

    /// `GET /api/attachments/:attachmentId/thumbnail`: an image's smaller picture.
    public func downloadThumbnail(attachmentId: String) async throws -> Data {
        try await client.sendForData(Endpoints.downloadAttachmentThumbnail, path: ["attachmentId": attachmentId])
    }
}
