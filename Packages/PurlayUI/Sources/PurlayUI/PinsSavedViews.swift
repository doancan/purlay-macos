import PurlayContract
import PurlayKit
import SwiftUI

/// The messages pinned in the open channel, newest first, each with who pinned it; choosing one goes to it, and a pin can be let go from here.
struct PinsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pinned").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if model.pinnedMessages.isEmpty {
                ContentUnavailableView(
                    "Nothing pinned", systemImage: "pin",
                    description: Text("Pin a message to keep it where the channel can find it.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(model.pinnedMessages, id: \.message.id) { pin in
                    HStack(alignment: .top) {
                        Button {
                            dismiss()
                            Task { await model.openMessage(pin.message) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(pin.message.sender?.displayName ?? "Purlay").font(.caption.bold())
                                    if let by = pin.pinnedBy {
                                        Text("pinned by \(by.displayName)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(pin.message.content).lineLimit(3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button("Unpin", systemImage: "pin.slash") { Task { await model.setPinned(false, pin.message) } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Unpin")
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 520, height: 420)
    }
}

/// What the person saved, by where it stands: in progress, completed, archived. Choosing one goes to it; a save can be let go from here.
struct SavedSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var state = SavedState.inProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Saved Messages").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("State", selection: $state) {
                Text("In progress").tag(SavedState.inProgress)
                Text("Completed").tag(SavedState.completed)
                Text("Archived").tag(SavedState.archived)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.savedLoading && model.savedItems.isEmpty {
                ProgressView("Loading saved messages…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.savedFailed && model.savedItems.isEmpty {
                ContentUnavailableView {
                    Label("Could Not Load Saved Messages", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try Again") { Task { await model.loadSaved(state) } }
                }
            } else if model.savedItems.isEmpty {
                ContentUnavailableView(
                    "Nothing saved here", systemImage: "bookmark",
                    description: Text("Save a message to come back to it.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.savedItems, id: \.id) { item in
                        HStack(alignment: .top) {
                            Button {
                                dismiss()
                                Task { await model.openMessage(item.message) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.chat.channels[item.message.channelId].map(Words.channelLabel) ?? "")
                                            .font(.caption.bold())
                                        Text(item.message.sender?.displayName ?? "Purlay").font(.caption)
                                            .foregroundStyle(
                                                .secondary)
                                    }
                                    Text(item.message.content).lineLimit(3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Menu {
                                if state != .completed {
                                    Button("Mark Completed", systemImage: "checkmark.circle") {
                                        Task { await model.setSavedState(.completed, item.message) }
                                    }
                                }
                                if state != .archived {
                                    Button("Archive", systemImage: "archivebox") {
                                        Task { await model.setSavedState(.archived, item.message) }
                                    }
                                }
                                if state != .inProgress {
                                    Button("Move to In Progress", systemImage: "arrow.uturn.backward") {
                                        Task { await model.setSavedState(.inProgress, item.message) }
                                    }
                                }
                                Divider()
                                Button("Remove from Saved", systemImage: "bookmark.slash") {
                                    Task { await model.removeSaved(item) }
                                }
                            } label: {
                                Label("Saved Message Actions", systemImage: "ellipsis.circle")
                            }
                            .labelStyle(.iconOnly)
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(model.savedUpdating.contains(item.message.id))
                        }
                    }
                    if model.savedHasMore {
                        Button(model.savedFailed ? "Try Loading More Again" : "Load More") {
                            Task { await model.loadMoreSaved() }
                        }
                        .disabled(model.savedLoading)
                    }
                    if model.savedLoading { ProgressView() }
                }
                .listStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 520, height: 440)
        .task(id: state) { await model.loadSaved(state) }
    }
}
