import AppKit
import PurlayContract
import PurlayKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a file comes from: the open panel, a drop, or the pasteboard. Each becomes the same thing: a name and bytes.
enum PickedFiles {
    /// Reads files at most one byte past what a message may hold, so a huge file is refused for being huge without being held in memory.
    static func read(_ urls: [URL]) async -> [PickedFile] {
        await Task.detached(priority: .userInitiated) {
            urls.compactMap { url -> PickedFile? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: ContractConstants.attachmentBytesMax + 1)) ?? Data()
                return PickedFile(name: url.lastPathComponent, data: data)
            }
        }.value
    }

    /// Files copied in the Finder, or a picture copied from anywhere: a screenshot has no file, only its pixels.
    @MainActor
    static func fromPasteboard(_ pasteboard: NSPasteboard) async -> [PickedFile] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL], !urls.isEmpty
        {
            return await read(urls)
        }
        if let png = pasteboard.data(forType: .png) { return [PickedFile(name: "Pasted image.png", data: png)] }
        if let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff),
            let png = image.representation(using: .png, properties: [:])
        {
            return [PickedFile(name: "Pasted image.png", data: png)]
        }
        return []
    }

    @MainActor
    static func choose() async -> [PickedFile] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose files to attach")
        guard panel.runModal() == .OK else { return [] }
        return await read(panel.urls)
    }

    static func pasteboardHasFiles(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.data(forType: .png) != nil || pasteboard.data(forType: .tiff) != nil
    }
}

private func sizeText(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

/// The files in a box, each saying where it stands: on its way, ready, or why not, with Retry only where trying again can help and
/// Remove always. A message goes when each is ready.
struct UploadChips: View {
    let model: AppModel
    let channel: Uuid
    let parent: Uuid?

    var body: some View {
        let held = model.uploads(channel: channel, parent: parent)
        if !held.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(held) { upload in UploadChip(model: model, upload: upload, channel: channel, parent: parent)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct UploadChip: View {
    let model: AppModel
    let upload: Upload
    let channel: Uuid
    let parent: Uuid?

    var body: some View {
        HStack(spacing: 6) {
            switch upload.state {
            case .uploading: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(upload.name).lineLimit(1).font(.callout)
                switch upload.state {
                case .uploading: Text("Sending… \(sizeText(upload.size))").font(.caption).foregroundStyle(.secondary)
                case .done: Text(sizeText(upload.size)).font(.caption).foregroundStyle(.secondary)
                case .failed(let failure): Text(Words.upload(failure)).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            if case .failed(let failure) = upload.state, failure.canRetry {
                Button("Retry") { Task { await model.retryUpload(upload.id, channel: channel, parent: parent) } }
                    .controlSize(.small)
            }
            Button {
                Task { await model.removeUpload(upload.id, channel: channel, parent: parent) }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel("Remove \(upload.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 280)
    }
}

/// What a message carries: a picture drawn small where it is, a file as a chip that saves it. The bytes come through the app, which holds
/// the session; there is no public address to a file.
struct AttachmentList: View {
    let model: AppModel
    let attachments: [PurlayContract.Attachment]

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(attachments, id: \.id) { attachment in
                    if attachment.kind == .image {
                        PictureView(model: model, attachment: attachment)
                    } else {
                        FileChip(model: model, attachment: attachment)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct PictureView: View {
    let model: AppModel
    let attachment: PurlayContract.Attachment
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .help(attachment.fileName)
                    .onTapGesture { save() }
                    .accessibilityLabel(attachment.fileName)
            } else if failed {
                FileChip(model: model, attachment: attachment)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 160, height: 100).overlay(
                    ProgressView())
            }
        }
        .task(id: attachment.id) {
            // The small picture if there is one, the picture itself if there is not.
            var data = await model.attachmentData(attachment, thumbnail: true)
            if data == nil { data = await model.attachmentData(attachment, thumbnail: false) }
            if let data, let loaded = NSImage(data: data) { image = loaded } else { failed = true }
        }
    }

    private func save() { Task { await FileSaving.save(model: model, attachment: attachment) } }
}

private struct FileChip: View {
    let model: AppModel
    let attachment: PurlayContract.Attachment

    var body: some View {
        Button {
            Task { await FileSaving.save(model: model, attachment: attachment) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.fileName).lineLimit(1)
                    Text(sizeText(attachment.sizeBytes)).font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Save \(attachment.fileName)…")
        .accessibilityLabel("\(attachment.fileName), \(sizeText(attachment.sizeBytes)). Save")
    }
}

@MainActor
enum FileSaving {
    /// Asks where, then writes the bytes the server brokered. Nothing is written without being asked for, and a name from a stranger never
    /// chooses a place: the panel starts at the downloads and the person decides.
    static func save(model: AppModel, attachment: PurlayContract.Attachment) async {
        guard let data = await model.attachmentData(attachment, thumbnail: false) else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = UploadRules.savingName(attachment.fileName)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            model.fileNotWritten()
        }
    }
}
