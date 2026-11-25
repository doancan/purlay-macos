import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// How long a status stays: the choices the web client offers, said in a person's words.
private enum StatusDuration: String, CaseIterable, Identifiable {
    case keep, thirtyMinutes, oneHour, fourHours, today, thisWeek

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .keep: "Don’t clear"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .fourHours: "4 hours"
        case .today: "Today"
        case .thisWeek: "This week"
        }
    }

    /// The moment the status ends, counted from `now`; `today` is the end of the day and the week is the server's limit.
    func end(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .keep: nil
        case .thirtyMinutes: now.addingTimeInterval(30 * 60)
        case .oneHour: now.addingTimeInterval(3_600)
        case .fourHours: now.addingTimeInterval(4 * 3_600)
        case .today: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case .thisWeek:
            now.addingTimeInterval(Double(ContractConstants.statusUntilMaxDays) * 86_400 - 60)
        }
    }
}

private let suggestedEmoji = ["🎧", "🍽️", "🌴", "🤒", "🗓️", "🚗", "🏠", "💻"]

/// The person's own profile, edited here: name, title, status and time zone. Saved together, and only when it has changed.
struct ProfileForm: View {
    let model: AppModel
    @State private var edit: ProfileEdit?
    @State private var original: ProfileEdit?
    @State private var duration = StatusDuration.keep
    @State private var saving = false
    @State private var saved = false

    private var changed: Bool {
        guard let edit, let original else { return false }
        return edit != original || duration != .keep
    }

    var body: some View {
        if let me = model.me {
            let binding = Binding(get: { edit ?? ProfileEdit(me) }, set: { edit = $0 })
            Group {
                Section("Profile") {
                    TextField("Name", text: binding.displayName)
                        .disabled(model.nameFollowsGitHub)
                    if model.nameFollowsGitHub {
                        Text("Your name comes from your GitHub account. Change it on GitHub and it updates here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("Handle", value: "@" + me.user.username)
                    TextField("Title", text: binding.title, prompt: Text("What you do here"))
                    if binding.wrappedValue.title.count > ContractConstants.profileTitleMax {
                        limitNote("Titles are at most \(ContractConstants.profileTitleMax) characters.")
                    }
                }
                Section("Status") {
                    HStack(spacing: Spacing.space2) {
                        Menu {
                            ForEach(suggestedEmoji, id: \.self) { emoji in
                                Button(emoji) { binding.statusEmoji.wrappedValue = emoji }
                            }
                            Divider()
                            Button("No Emoji") { binding.statusEmoji.wrappedValue = "" }
                        } label: {
                            Text(binding.wrappedValue.statusEmoji.isEmpty ? "🙂" : binding.wrappedValue.statusEmoji)
                                .opacity(binding.wrappedValue.statusEmoji.isEmpty ? 0.35 : 1)
                        }
                        .menuStyle(.button).fixedSize()
                        .accessibilityLabel("Status emoji")
                        TextField("Status", text: binding.status, prompt: Text("What are you up to?"))
                    }
                    if binding.wrappedValue.status.count > ContractConstants.profileStatusMax {
                        limitNote("Statuses are at most \(ContractConstants.profileStatusMax) characters.")
                    }
                    Picker("Clear after", selection: $duration) {
                        ForEach(StatusDuration.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(binding.wrappedValue.status.isEmpty && binding.wrappedValue.statusEmoji.isEmpty)
                    if duration == .keep, let until = binding.wrappedValue.statusUntil {
                        Text("Clears \(until.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Time Zone") {
                    Picker("Time zone", selection: binding.timeZone) {
                        Text("Not set").tag("")
                        ForEach(Self.zones(including: binding.wrappedValue.timeZone), id: \.self) { Text($0).tag($0) }
                    }
                    Button("Use This Mac’s Time Zone") { binding.timeZone.wrappedValue = TimeZone.current.identifier }
                        .disabled(binding.wrappedValue.timeZone == TimeZone.current.identifier)
                }
                Section {
                    HStack {
                        if saving { ProgressView().controlSize(.small) }
                        if saved && !changed {
                            Label("Saved", systemImage: "checkmark").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revert") {
                            edit = original
                            duration = .keep
                        }
                        .disabled(!changed || saving)
                        Button("Save", action: save)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!changed || saving || binding.wrappedValue.problem != nil)
                    }
                    ForEach(model.notices) { notice in
                        NoticeBanner(notice: notice) { model.dismiss(notice) }
                    }
                }
            }
            .onAppear { load(me) }
            .onChange(of: me.profile) { _, _ in if !changed { load(me) } }
        }
    }

    private func limitNote(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption).foregroundStyle(.red)
    }

    private func load(_ me: MeResponse) {
        let fresh = ProfileEdit(me)
        original = fresh
        edit = fresh
        duration = .keep
    }

    private func save() {
        guard var form = edit else { return }
        if duration != .keep { form.statusUntil = duration.end(from: Date()) }
        saved = false
        saving = true
        Task {
            let ok = await model.saveProfile(form)
            saving = false
            if ok, let fresh = model.me {
                load(fresh)
                saved = true
            }
        }
    }

    /// Every zone the system knows, with one the server holds that this Mac does not list kept in the list.
    private static func zones(including current: String) -> [String] {
        var all = TimeZone.knownTimeZoneIdentifiers.sorted()
        if !current.isEmpty, !all.contains(current) { all.insert(current, at: 0) }
        return all
    }
}
