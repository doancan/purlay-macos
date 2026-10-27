import Foundation
import PurlayContract

extension AppModel {
    // MARK: Files

    /// How many downloaded files and pictures are kept, and how many bytes they may add up to: a feed of pictures is not a leak.
    static let attachmentCacheMax = 64
    private static let attachmentCacheBytesMax = 48 * 1_024 * 1_024
    var attachmentCacheCount: Int { attachmentCache.count }

    public func uploads(channel: Uuid, parent: Uuid?) -> [Upload] {
        uploadsByPlace[Place(channel: channel, parent: parent)] ?? []
    }

    /// Whether what is in a box can be sent: words or files, no file failed, and no send already waiting for its files. A file still on
    /// its way does not stop it: the send waits for it and goes when the files land (D-171). One that failed holds it until it is
    /// retried or removed.
    public func canSend(text: String, channel: Uuid, parent: Uuid?) -> Bool {
        let place = Place(channel: channel, parent: parent)
        guard waitingSends[place] == nil else { return false }
        let held = uploadsByPlace[place] ?? []
        guard !held.contains(where: \.hasFailed) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !held.isEmpty
    }

    /// Whether a send is waiting for its files in a box: the box shows it, and takes no second send meanwhile.
    public func isWaiting(channel: Uuid, parent: Uuid?) -> Bool {
        waitingSends[Place(channel: channel, parent: parent)] != nil
    }

    /// The words of a send that could not go, once, for the box they belong to to take back; nil when there are none.
    public func takeHandedBack(channel: Uuid, parent: Uuid?) -> String? {
        let place = Place(channel: channel, parent: parent)
        // Writes only when there is something to give: a view may ask while it is drawn, and a write there would draw it again.
        guard handedBack[place] != nil else { return nil }
        return handedBack.removeValue(forKey: place)
    }

    /// Sends what a box holds, or, with a file still on its way, takes the words and waits: nothing leaves before every file is there.
    func submit(_ words: String, _ place: Place) {
        if (uploadsByPlace[place] ?? []).contains(where: \.isUploading) {
            waitingSends[place] = words
            setDraft("", for: place.channel, parent: place.parent)
        } else {
            dispatch(words, place)
        }
    }

    private func dispatch(_ words: String, _ place: Place) {
        let attachments = (uploadsByPlace[place] ?? []).compactMap(\.attachment)
        engine?.send(
            Outgoing(channelID: place.channel, content: words, parentID: place.parent, attachments: attachments))
        uploadsByPlace[place] = nil
        setDraft("", for: place.channel, parent: place.parent)
    }

    /// A waiting send goes when its last file lands. If a file failed or was taken off it does not go: its words are handed back to the
    /// box, and a failure says where.
    private func settle(_ place: Place) {
        guard let words = waitingSends[place] else { return }
        let held = uploadsByPlace[place] ?? []
        guard !held.contains(where: \.isUploading) else { return }
        waitingSends[place] = nil
        if held.isEmpty || held.contains(where: \.hasFailed) {
            handedBack[place] = words
            handedBackCount += 1
            if held.contains(where: \.hasFailed) {
                let name = channels.first { $0.id == place.channel }.map(Self.title) ?? ""
                say(.sendHeld(name))
            }
        } else {
            dispatch(words, place)
        }
    }

    /// Chosen files are uploaded at once, a few at a time, each under an id of the app's making so that the same upload again is the same
    /// upload. A file that cannot be sent is a failed upload that says why and is never asked of the server.
    public func attach(_ files: [PickedFile], channel: Uuid, parent: Uuid?) async {
        guard api != nil, workspace != nil else { return }
        let place = Place(channel: channel, parent: parent)
        let room = max(0, ContractConstants.attachmentsPerMessageMax - (uploadsByPlace[place]?.count ?? 0))
        if files.count > room { say(.tooManyFiles) }
        var started: [Uuid] = []
        for file in files.prefix(room) {
            let name = UploadRules.name(file.name)
            let id = uploadIDs.next()
            if let refusal = UploadRules.check(name: name, size: file.data.count) {
                uploadsByPlace[place, default: []].append(
                    Upload(id: id, name: name, size: file.data.count, state: .failed(refusal)))
            } else {
                uploadBytes[id] = file.data
                uploadsByPlace[place, default: []].append(
                    Upload(id: id, name: name, size: file.data.count, state: .uploading))
                started.append(id)
            }
        }
        // A few at a time: a folder of pictures is not a hundred requests at once.
        for batch in stride(from: 0, to: started.count, by: 3) {
            let running = started[batch..<min(batch + 3, started.count)].map { id in
                Task { @MainActor in await runUpload(id, place) }
            }
            for task in running { await task.value }
        }
    }

    private func upload(_ id: Uuid, _ place: Place) -> Upload? { uploadsByPlace[place]?.first { $0.id == id } }

    private func setUpload(_ id: Uuid, _ place: Place, _ state: Upload.State) {
        guard let at = uploadsByPlace[place]?.firstIndex(where: { $0.id == id }) else { return }
        uploadsByPlace[place]?[at].state = state
    }

    private func runUpload(_ id: Uuid, _ place: Place) async {
        guard let api, let workspace, let held = upload(id, place), let data = uploadBytes[id] else { return }
        do {
            let attachment = try await api.uploadFile(
                workspaceId: workspace.id.value, id: id, name: held.name, bytes: data)
            guard upload(id, place) != nil else {
                // Removed while it was on its way: the server has it, and it is let go.
                try? await api.discardAttachment(attachmentId: id.value)
                return
            }
            setUpload(id, place, .done(attachment))
            uploadBytes[id] = nil
            settle(place)
        } catch {
            guard upload(id, place) != nil else { return }
            let failure = UploadFailure.from(error)
            setUpload(id, place, .failed(failure))
            if !failure.canRetry { uploadBytes[id] = nil }
            settle(place)
        }
    }

    /// Sends the same file again under the same id, when trying again can be answered differently.
    public func retryUpload(_ id: Uuid, channel: Uuid, parent: Uuid?) async {
        let place = Place(channel: channel, parent: parent)
        guard let held = upload(id, place), case .failed(let failure) = held.state, failure.canRetry,
            uploadBytes[id] != nil
        else { return }
        setUpload(id, place, .uploading)
        await runUpload(id, place)
    }

    /// Takes a file off: the server's copy of one that went up is let go, and one still on its way is not waited for.
    public func removeUpload(_ id: Uuid, channel: Uuid, parent: Uuid?) async {
        let place = Place(channel: channel, parent: parent)
        guard let held = upload(id, place) else { return }
        uploadsByPlace[place]?.removeAll { $0.id == id }
        if uploadsByPlace[place]?.isEmpty == true { uploadsByPlace[place] = nil }
        uploadBytes[id] = nil
        settle(place)
        if case .done = held.state, let api { try? await api.discardAttachment(attachmentId: id.value) }
    }

    /// What was attached, or its picture, read once and kept; nil when it is not there to read.
    public func attachmentData(_ attachment: Attachment, thumbnail: Bool) async -> Data? {
        let key = attachment.id.value + (thumbnail ? ":thumbnail" : "")
        if let kept = attachmentCache[key] { return kept }
        guard let api else { return nil }
        do {
            let data =
                thumbnail
                ? try await api.downloadThumbnail(attachmentId: attachment.id.value)
                : try await api.downloadAttachment(attachmentId: attachment.id.value)
            remember(data, key)
            return data
        } catch {
            return nil
        }
    }

    private func remember(_ data: Data, _ key: String) {
        guard data.count <= Self.attachmentCacheBytesMax else { return }
        attachmentCache[key] = data
        attachmentCacheOrder.append(key)
        attachmentCacheBytes += data.count
        while attachmentCache.count > Self.attachmentCacheMax || attachmentCacheBytes > Self.attachmentCacheBytesMax,
            let oldest = attachmentCacheOrder.first
        {
            attachmentCacheOrder.removeFirst()
            attachmentCacheBytes -= attachmentCache.removeValue(forKey: oldest)?.count ?? 0
        }
    }
}
