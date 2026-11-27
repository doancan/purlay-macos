import PurlayContract
import PurlayKit
import SwiftUI

struct ReminderSheet: View {
    let model: AppModel
    let message: Message
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    @State private var busy = false
    @State private var feedback: TimingActionFeedback?

    init(model: AppModel, message: Message) {
        self.model = model
        self.message = message
        _date = State(initialValue: model.reminder(for: message)?.remindAt.date ?? .now.addingTimeInterval(3_600))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remind Me").font(.title2.bold())
            Text(message.content.isEmpty ? "Attachment message" : message.content).lineLimit(4)
            FutureTimePicker(date: $date)
            Text("Only you will be reminded. Allow Purlay notifications to receive a reminder while the app is closed.")
                .font(.caption).foregroundStyle(.secondary)
            if let feedback { feedback }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Set Reminder") {
                    Task {
                        busy = true
                        feedback = nil
                        defer { busy = false }
                        do {
                            try await model.setReminder(for: message, at: date)
                            dismiss()
                        } catch { feedback = TimingActionFeedback(error) }
                    }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 440).disabled(busy).interactiveDismissDisabled(busy)
    }
}

struct RemindersSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var busy: Uuid?
    @State private var feedback: TimingActionFeedback?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Reminders", subtitle: "Messages you asked to come back to.", image: "bell.badge",
                refresh: { Task { await model.loadReminders() } }, refreshing: model.remindersLoading
            ) { dismiss() }
            Divider()
            if let feedback { feedback.padding(.horizontal) }
            if model.remindersFailed {
                HStack {
                    Text("Reminders could not be refreshed.")
                    Button("Retry") { Task { await model.loadReminders() } }
                }.padding()
            }
            if model.reminderItems.isEmpty {
                if model.remindersLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "No pending reminders", systemImage: "bell.badge",
                        description: Text("Choose Remind Me from a message’s menu. Due reminders appear in Inbox.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(model.reminderItems, id: \.id) { reminder in
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            Task {
                                await model.openMessage(reminder.message)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(
                                    model.chat.channels[reminder.message.channelId].map(Words.channelLabel)
                                        ?? "Conversation"
                                ).font(.headline)
                                Text(reminder.message.content.isEmpty ? "Attachment message" : reminder.message.content)
                                    .lineLimit(3)
                                Label(
                                    reminder.remindAt.date.formatted(date: .abbreviated, time: .shortened),
                                    systemImage: "bell"
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu {
                            // The window owns this editor so a refresh that closes the list cannot close it too.
                            Button("Change Time…") { model.reminderTarget = reminder.message }
                            Button("Cancel Reminder", role: .destructive) {
                                Task {
                                    busy = reminder.id
                                    feedback = nil
                                    defer { busy = nil }
                                    do { try await model.cancelReminder(reminder) } catch {
                                        feedback = TimingActionFeedback(error)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }.menuStyle(.borderlessButton).fixedSize()
                            .accessibilityLabel("Reminder actions").disabled(busy == reminder.id)
                    }.padding(.vertical, 6)
                }
            }
        }.modifier(ModalFrame(width: 600, height: 500))
            .task { await model.loadReminders() }
    }
}
