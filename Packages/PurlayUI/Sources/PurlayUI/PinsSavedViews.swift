import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

struct PinsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var failed = false
    @State private var revision = 0

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Pinned Messages", subtitle: "Important messages, kept with the conversation.", image: "pin"
            ) {
                dismiss()
            }
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Size.sizePalette, height: Size.sizeDialog - Spacing.space10)
        .task(id: revision) {
            loading = true
            let success = await model.refreshPins()
            guard !Task.isCancelled else { return }
            failed = !success
            loading = false
        }
    }

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView("Loading pinned messages…")
        } else if failed {
            ContentUnavailableView {
                Label("Couldn't Load Pinned Messages", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { revision &+= 1 }.buttonStyle(.glass)
            }
        } else if model.pinnedMessages.isEmpty {
            EmptyState(
                "No Pinned Messages", systemImage: "pin",
                description: Text("Pin a message to keep it where the channel can find it."))
        } else {
            List(model.pinnedMessages, id: \.message.id) { pin in
                HStack(alignment: .top, spacing: Spacing.space3) {
                    Button {
                        dismiss()
                        Task { await model.openMessage(pin.message) }
                    } label: {
                        CollectionMessagePreview(
                            message: pin.message,
                            detail: pin.pinnedBy.map { String(localized: "Pinned by \($0.displayName)") })
                    }
                    .buttonStyle(.plain)
                    Button("Unpin", systemImage: "pin.slash") {
                        Task { await model.setPinned(false, pin.message) }
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).help("Unpin")
                }
                .padding(.vertical, Spacing.space2)
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
        }
    }
}

struct SavedSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var state = SavedState.inProgress
    @State private var revision = 0

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Saved Messages", subtitle: "Your own space to keep track of what matters.", image: "bookmark"
            ) {
                dismiss()
            }
            Picker("State", selection: $state) {
                Text("In Progress").tag(SavedState.inProgress)
                Text("Completed").tag(SavedState.completed)
                Text("Archived").tag(SavedState.archived)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Spacing.space5)
            .padding(.bottom, Spacing.space4)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Size.sizePalette, height: Size.sizeDialog - Spacing.space10)
        .task(id: "\(state.rawValue)-\(revision)") { await model.loadSaved(state) }
    }

    @ViewBuilder private var content: some View {
        switch model.savedStatus {
        case .idle, .loading:
            ProgressView("Loading saved messages…")
        case .failed:
            ContentUnavailableView {
                Label("Couldn't Load Saved Messages", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { revision &+= 1 }.buttonStyle(.glass)
            }
        case .loaded:
            if model.savedItems.isEmpty {
                EmptyState(
                    emptyTitle,
                    systemImage: state == .completed
                        ? "checkmark.circle" : state == .archived ? "archivebox" : "bookmark",
                    description: Text(emptyDescription))
            } else {
                List {
                    ForEach(model.savedItems, id: \.id) { item in
                        SavedRow(model: model, item: item) { dismiss() }
                    }
                    if model.savedHasMore {
                        VStack(spacing: Spacing.space2) {
                            if model.savedPaginationFailed {
                                Text("Couldn't load more messages. Try again.")
                                    .font(.caption).foregroundStyle(Colors.dangerText.style)
                            }
                            Button {
                                Task { await model.loadMoreSaved() }
                            } label: {
                                if model.loadingMoreSaved {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("Load More")
                                }
                            }
                            .buttonStyle(.glass).disabled(model.loadingMoreSaved)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, Spacing.space2)
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyTitle: LocalizedStringKey {
        switch state {
        case .completed: "Nothing Completed Yet"
        case .archived: "No Archived Messages"
        default: "No Saved Messages"
        }
    }

    private var emptyDescription: LocalizedStringKey {
        switch state {
        case .completed: "Mark a saved message as completed when you're done with it."
        case .archived: "Archive saved messages to keep them for later."
        default: "Save a message from any conversation to come back to it here."
        }
    }
}

private struct SavedRow: View {
    let model: AppModel
    let item: SavedItem
    let close: () -> Void
    @State private var changing = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .top, spacing: Spacing.space3) {
                Button {
                    close()
                    Task { await model.openMessage(item.message) }
                } label: {
                    CollectionMessagePreview(
                        message: item.message,
                        detail: model.chat.channels[item.message.channelId].map(Words.channelLabel))
                }
                .buttonStyle(.plain)
                Menu {
                    if item.state != .inProgress {
                        Button("Move to In Progress", systemImage: "circle") { move(.inProgress) }
                    }
                    if item.state != .completed {
                        Button("Mark Completed", systemImage: "checkmark.circle") { move(.completed) }
                    }
                    if item.state != .archived {
                        Button("Archive", systemImage: "archivebox") { move(.archived) }
                    }
                    Divider()
                    Button("Remove from Saved", systemImage: "bookmark.slash") {
                        changing = true
                        Task {
                            await model.removeSaved(item)
                            failed = model.isSaved(item.message)
                            changing = false
                        }
                    }
                } label: {
                    Label("Message Actions", systemImage: "ellipsis")
                        .labelStyle(.iconOnly).frame(width: Size.sizeIconLg, height: Size.sizeIconLg)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(changing)
                .help("Manage saved message")
            }
            if failed {
                Label("Couldn't update this message. Try again.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Colors.dangerText.style)
            }
        }
        .padding(.vertical, Spacing.space2)
    }

    private func move(_ state: SavedState) {
        guard !changing else { return }
        changing = true
        failed = false
        Task {
            failed = !(await model.moveSaved(item, to: state))
            changing = false
        }
    }
}

private struct CollectionMessagePreview: View {
    let message: Message
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.space3) {
            Avatar(user: message.sender, size: Size.sizeAvatar)
            VStack(alignment: .leading, spacing: Spacing.space1) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                    Text(message.sender?.displayName ?? "Purlay").font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: Spacing.space1)
                    Text(message.createdAt.date, style: .date).font(.caption).foregroundStyle(
                        NativePalette.secondary.style
                    ).fixedSize()
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(NativePalette.secondary.style).lineLimit(1)
                }
                if message.deletedAt != nil {
                    Text("This message was deleted.").font(.callout).foregroundStyle(NativePalette.secondary.style)
                } else if !message.content.isEmpty {
                    Text(message.content).font(.callout).lineLimit(3)
                } else if let file = message.attachments.first {
                    Label(file.fileName, systemImage: "paperclip").font(.callout).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }
}
