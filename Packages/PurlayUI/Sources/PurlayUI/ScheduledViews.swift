import PurlayContract
import PurlayKit
import SwiftUI

struct FutureTimePicker: View {
    @Binding var date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("In one hour") { date = Date.now.addingTimeInterval(3_600) }
                Button("Tomorrow at 9 AM") {
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
                    date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
                }
            }
            DatePicker("When", selection: $date, displayedComponents: [.date, .hourAndMinute])
            Text("Time zone: \(TimeZone.current.identifier)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ScheduleMessageSheet: View {
    let model: AppModel
    let channel: Uuid
    let parent: Uuid?
    let existing: ScheduledMessage?
    let completed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var id = Uuid(UUID())
    @State private var text: String
    @State private var date: Date
    @State private var files: [Attachment]
    @State private var busy = false
    @State private var failure: String?

    init(
        model: AppModel, channel: Uuid, parent: Uuid?, text: String, existing: ScheduledMessage? = nil,
        completed: @escaping () -> Void = {}
    ) {
        self.model = model
        self.channel = channel
        self.parent = parent
        self.existing = existing
        self.completed = completed
        _text = State(initialValue: text)
        _date = State(
            initialValue: existing.map {
                $0.sendAt.date > .now.addingTimeInterval(60) ? $0.sendAt.date : .now.addingTimeInterval(3_600)
            } ?? .now.addingTimeInterval(3_600))
        _files = State(
            initialValue: existing?.attachments
                ?? model.uploads(channel: channel, parent: parent).compactMap(\.attachment))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "Schedule Message" : "Edit Scheduled Message").font(.title2.bold())
            Text(model.chat.channels[channel].map(Words.channelLabel) ?? "Conversation").foregroundStyle(.secondary)
            if existing != nil {
                TextEditor(text: $text).font(.body).frame(minHeight: 100, maxHeight: 160)
                    .accessibilityLabel("Message")
            } else {
                Text(text.isEmpty ? "Attachment message" : text).lineLimit(5)
            }
            if !files.isEmpty {
                ForEach(files, id: \.id) { file in
                    HStack {
                        Label(file.fileName, systemImage: "paperclip").lineLimit(1)
                        if existing != nil {
                            Spacer()
                            Button("Remove", systemImage: "xmark") { files.removeAll { $0.id == file.id } }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    }.font(.caption)
                }
            }
            FutureTimePicker(date: $date)
            Text("Sends even when Purlay is closed. You can edit or cancel it in Scheduled.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(existing == nil ? "Schedule" : "Save Changes") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 440).disabled(busy).interactiveDismissDisabled(busy)
    }

    private func save() async {
        busy = true
        failure = nil
        defer { busy = false }
        do {
            if let existing {
                try await model.updateScheduled(existing, text: text, files: files, at: date)
            } else {
                try await model.scheduleDraft(id: id, text: text, channel: channel, parent: parent, at: date)
            }
            completed()
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}

struct ScheduledSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ScheduledMessage?
    @State private var cancelling: ScheduledMessage?
    @State private var busy: Uuid?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Scheduled Messages").font(.title2.bold())
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadScheduled() } }
                    .labelStyle(.iconOnly).disabled(model.scheduledLoading)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            if let failure { Text(failure).foregroundStyle(.red).padding(.horizontal) }
            if model.scheduledFailed {
                HStack {
                    Text("Scheduled messages could not be refreshed.")
                    Button("Retry") { Task { await model.loadScheduled() } }
                }.padding()
            }
            if model.scheduledItems.isEmpty {
                if model.scheduledLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No scheduled messages", systemImage: "clock",
                        description: Text("Choose Schedule beside Send in a conversation.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(model.scheduledItems, id: \.id) { message in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.chat.channels[message.channelId].map(Words.channelLabel) ?? "Conversation").font(
                                .headline)
                            if message.parentId != nil {
                                Label("Reply", systemImage: "arrowshape.turn.up.left").font(.caption)
                            }
                            Spacer()
                            Menu {
                                Button("Edit…") { editing = message }
                                Button("Cancel Scheduled Message…", role: .destructive) { cancelling = message }
                            } label: {
                                Image(systemName: "ellipsis")
                            }.menuStyle(.borderlessButton).fixedSize()
                                .accessibilityLabel("Scheduled message actions").disabled(busy == message.id)
                        }
                        Text(message.content.isEmpty ? "Attachment message" : message.content).lineLimit(3)
                        if !message.attachments.isEmpty {
                            Label("\(message.attachments.count) attachment(s)", systemImage: "paperclip").font(.caption)
                        }
                        if message.state == .failed {
                            Label(
                                "Could not send. Check access and attachments, then edit to try again.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption).foregroundStyle(.red)
                        } else {
                            Label(
                                message.sendAt.date.formatted(date: .abbreviated, time: .shortened),
                                systemImage: "clock"
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
            }
        }.frame(width: 600, height: 500)
            .task {
                await model.loadScheduled()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard !Task.isCancelled else { return }
                    await model.loadScheduled()
                }
            }
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                if let editing {
                    ScheduleMessageSheet(
                        model: model, channel: editing.channelId, parent: editing.parentId, text: editing.content,
                        existing: editing)
                }
            }
            .confirmationDialog(
                "Cancel this scheduled message?",
                isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                presenting: cancelling
            ) { message in
                Button("Cancel Scheduled Message", role: .destructive) {
                    Task {
                        busy = message.id
                        failure = nil
                        defer { busy = nil }
                        do { try await model.cancelScheduled(message) } catch { failure = error.localizedDescription }
                    }
                }
            } message: { _ in
                Text("It will not be sent. This cannot be undone.")
            }
    }
}
