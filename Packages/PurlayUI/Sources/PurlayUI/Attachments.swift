import AppKit
import PurlayContract
import PurlayKit
import PurlayTokens
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Where a file comes from: the open panel, a drop, or the pasteboard. Each becomes the same thing: a name and bytes.
enum PickedFiles {
    /// What was read, and the names of what could not be: a file that is gone, or that the sandbox will not open, is said and
    /// not dropped, and a read that failed is never taken for an empty file.
    struct Batch: Sendable {
        var files: [PickedFile] = []
        var unreadable: [String] = []
    }

    /// Reads files at most one byte past what a message may hold, so a huge file is refused for being huge without being held in memory.
    static func read(_ urls: [URL]) async -> Batch {
        await Task.detached(priority: .userInitiated) {
            var batch = Batch()
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: ContractConstants.attachmentBytesMax + 1) ?? Data()
                    batch.files.append(PickedFile(name: url.lastPathComponent, data: data))
                } catch {
                    batch.unreadable.append(url.lastPathComponent)
                }
            }
            return batch
        }.value
    }

    /// Files copied in the Finder, or a picture copied from anywhere: a screenshot has no file, only its pixels.
    @MainActor
    static func fromPasteboard(_ pasteboard: NSPasteboard) async -> Batch {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL], !urls.isEmpty
        {
            return await read(urls)
        }
        if let png = pasteboard.data(forType: .png) {
            return Batch(files: [PickedFile(name: "Pasted image.png", data: png)])
        }
        if let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff),
            let png = image.representation(using: .png, properties: [:])
        {
            return Batch(files: [PickedFile(name: "Pasted image.png", data: png)])
        }
        return Batch()
    }

    @MainActor
    static func choose() async -> Batch {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose files to attach")
        guard panel.runModal() == .OK else { return Batch() }
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
                HStack(spacing: Spacing.space2) {
                    ForEach(held) { upload in
                        UploadChip(model: model, upload: upload, channel: channel, parent: parent)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .padding(.vertical, Stroke.strokeFocus)
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
        HStack(spacing: Spacing.space2) {
            switch upload.state {
            case .uploading: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(NativePalette.success.style)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(NativePalette.danger.style)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(upload.name).lineLimit(1).truncationMode(.middle).font(.callout)
                switch upload.state {
                case .uploading: Text("Sending… \(sizeText(upload.size))").font(.caption).foregroundStyle(.secondary)
                case .done: Text(sizeText(upload.size)).font(.caption).foregroundStyle(.secondary)
                case .failed(let failure):
                    Text(Words.upload(failure)).font(.caption).foregroundStyle(Colors.dangerText.style).lineLimit(2)
                }
            }
            if case .failed(let failure) = upload.state, failure.canRetry {
                Button("Retry") { Task { await model.retryUpload(upload.id, channel: channel, parent: parent) } }
                    .controlSize(.small)
            }
            Button {
                Task { await model.removeUpload(upload.id, channel: channel, parent: parent) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel("Remove \(upload.name)")
        }
        .padding(.horizontal, Spacing.space2)
        .padding(.vertical, Spacing.space1)
        .background(.fill.tertiary, in: .rect(cornerRadius: Radius.radiusLg))
        .frame(maxWidth: Size.sizeAttachment)
    }
}

/// What a message carries: a picture drawn small where it is, a file as a chip. A click previews either in Quick Look, as the
/// Finder does; saving is in the menu. The bytes come through the app, which holds the session; there is no public address to a file.
struct AttachmentList: View {
    let model: AppModel
    let attachments: [PurlayContract.Attachment]
    @State private var previewing: URL?
    @State private var previews: [URL] = []

    var body: some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                ForEach(attachments, id: \.id) { attachment in
                    Group {
                        if attachment.kind == .image {
                            PictureView(model: model, attachment: attachment, preview: { preview(attachment) })
                        } else {
                            FileChip(model: model, attachment: attachment, preview: { preview(attachment) })
                        }
                    }
                    .contextMenu { AttachmentMenu(model: model, attachment: attachment) { preview(attachment) } }
                }
            }
            .padding(.top, Stroke.strokeFocus)
            .quickLookPreview($previewing, in: previews)
        }
    }

    /// Writes every file of the message to the app's own caches (once each) and opens Quick Look on the chosen one, so the arrow
    /// keys step through the rest as they do in the Finder.
    private func preview(_ attachment: PurlayContract.Attachment) {
        Task {
            var urls: [URL] = []
            for item in attachments {
                if let url = await QuickLookFiles.url(model: model, attachment: item) { urls.append(url) }
            }
            guard let chosen = await QuickLookFiles.url(model: model, attachment: attachment) else {
                NSSound.beep()
                return
            }
            previews = urls
            previewing = chosen
        }
    }
}

/// What can be done to a file: look at it, save it, copy it, share it.
private struct AttachmentMenu: View {
    let model: AppModel
    let attachment: PurlayContract.Attachment
    let preview: () -> Void

    var body: some View {
        Button("Quick Look", systemImage: "eye", action: preview)
        Button("Save As…", systemImage: "square.and.arrow.down") {
            Task { await FileSaving.save(model: model, attachment: attachment) }
        }
        if attachment.kind == .image {
            Button("Copy Image", systemImage: "doc.on.doc") {
                Task {
                    guard let data = await model.attachmentData(attachment, thumbnail: false),
                        let image = NSImage(data: data)
                    else { return NSSound.beep() }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
        }
        Button("Copy File Name", systemImage: "textformat") { Clipboard.copy(attachment.fileName) }
    }
}

private struct PictureView: View {
    let model: AppModel
    let attachment: PurlayContract.Attachment
    let preview: () -> Void
    @State private var image: NSImage?
    @State private var failed = false

    /// The picture's own shape, known before its bytes, so the feed keeps its place when it lands.
    private var aspect: Double? {
        guard let width = attachment.width, let height = attachment.height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    var body: some View {
        Group {
            if let image {
                Button(action: preview) {
                    Image(nsImage: image).resizable().scaledToFit()
                }
                .buttonStyle(.plain)
                .frame(maxWidth: Size.sizeAttachment + Spacing.space10, maxHeight: Size.sizeSidebar)
                .clipShape(.rect(cornerRadius: Radius.radiusXl))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.radiusXl)
                        .strokeBorder(NativePalette.divider.style, lineWidth: Stroke.strokeHairline)
                }
                .help("\(attachment.fileName): click to preview")
                .accessibilityLabel(attachment.fileName)
                .accessibilityHint("Opens in Quick Look")
                .transition(.opacity)
            } else if failed {
                FileChip(model: model, attachment: attachment, preview: preview)
            } else {
                RoundedRectangle(cornerRadius: Radius.radiusXl)
                    .fill(NativePalette.fill.style)
                    .aspectRatio(aspect ?? 1.6, contentMode: .fit)
                    .frame(maxWidth: Size.sizeAttachment + Spacing.space10, maxHeight: Size.sizeSidebar)
                    .overlay(ProgressView().controlSize(.small))
                    .accessibilityLabel(Text("Loading \(attachment.fileName)"))
            }
        }
        .animation(Motion.easingStandard.animation(Motion.durationOverlay), value: image != nil)
        .task(id: attachment.id) {
            // The small picture if there is one, the picture itself if there is not; decoded away from the main actor.
            var data = await model.attachmentData(attachment, thumbnail: true)
            if data == nil { data = await model.attachmentData(attachment, thumbnail: false) }
            if let data, let loaded = await QuickLookFiles.image(data) { image = loaded } else { failed = true }
        }
    }
}

private struct FileChip: View {
    let model: AppModel
    let attachment: PurlayContract.Attachment
    let preview: () -> Void
    @State private var saving = false

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Button(action: preview) {
                HStack(spacing: Spacing.space2) {
                    Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: attachment.mimeType) ?? .data))
                        .resizable().frame(width: Size.sizeAvatar, height: Size.sizeAvatar)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(attachment.fileName).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(NativePalette.ink.style)
                        Text(sizeText(attachment.sizeBytes)).font(.caption).foregroundStyle(
                            NativePalette.secondary.style)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Preview \(attachment.fileName)")
            .accessibilityLabel("\(attachment.fileName), \(sizeText(attachment.sizeBytes))")
            .accessibilityHint("Opens in Quick Look")
            Button {
                saving = true
                Task {
                    await FileSaving.save(model: model, attachment: attachment)
                    saving = false
                }
            } label: {
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(NativePalette.secondary.style)
            .disabled(saving)
            .frame(width: Size.sizeIconLg, height: Size.sizeIconLg)
            .help("Save \(attachment.fileName)…")
            .accessibilityLabel("Save \(attachment.fileName)")
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
        .frame(maxWidth: Size.sizeAttachment, alignment: .leading)
        .background(NativePalette.fill.style, in: .rect(cornerRadius: Radius.radiusLg))
    }
}

/// Files Quick Look can open: the bytes written once into the app's caches under the file's own (made safe) name.
enum QuickLookFiles {
    @MainActor
    static func url(model: AppModel, attachment: PurlayContract.Attachment) async -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appending(path: "Previews/\(attachment.id.value)", directoryHint: .isDirectory)
        let url = folder.appending(path: UploadRules.savingName(attachment.fileName))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = await model.attachmentData(attachment, thumbnail: false) else { return nil }
        return await write(data, to: url, in: folder)
    }

    private static func write(_ data: Data, to url: URL, in folder: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }.value
    }

    /// Decodes a picture off the main actor, so a large one never stalls the feed.
    static func image(_ data: Data) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { NSImage(data: data) }.value
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
