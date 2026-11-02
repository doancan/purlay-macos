import Foundation
import PurlayContract
import PurlayKit
import SwiftUI

extension Words {
    static func savedSearchFailure(_ failure: SavedSearchFailure) -> String {
        switch failure {
        case .invalid: String(localized: "Give the search a name, and words or a filter to search for.")
        case .limit: String(localized: "You have saved as many searches as the server keeps. Delete one first.")
        case .notFound: String(localized: "That saved search no longer exists.")
        case .failed: String(localized: "The change could not be saved. Check your connection and try again.")
        case .sessionChanged: String(localized: "The account changed. Try again in the current account.")
        }
    }

    /// The filters of a search past its words, in a few words each: a recent or saved search's second line.
    @MainActor static func searchSummary(
        channel: Uuid?, sender: Uuid?, filters: SearchFilters?, model: AppModel
    ) -> [String] {
        var parts: [String] = []
        if let channel = channel.flatMap({ model.chat.channels[$0] }) { parts.append(channelLabel(channel)) }
        if let sender = model.workspacePeople.first(where: { $0.id == sender }) { parts.append(sender.displayName) }
        guard let filters else { return parts }
        switch filters.status {
        case .open?: parts.append(String(localized: "Open"))
        case .resolved?: parts.append(String(localized: "Resolved"))
        case .unknown(let value)?: parts.append(value)
        case nil: break
        }
        if filters.question != nil { parts.append(String(localized: "Questions")) }
        switch filters.kind {
        case .code?: parts.append(String(localized: "Code"))
        case .file?: parts.append(String(localized: "Attachments"))
        case .unknown(let value)?: parts.append(value)
        case nil: break
        }
        if let repository = filters.repository { parts.append(repository) }
        if let since = filters.since {
            parts.append(String(localized: "From \(since.date.formatted(date: .abbreviated, time: .omitted))"))
        }
        if let until = filters.until {
            parts.append(String(localized: "Before \(until.date.formatted(date: .abbreviated, time: .omitted))"))
        }
        return parts
    }

    @MainActor static func searchSummary(_ criteria: SearchCriteria, model: AppModel) -> [String] {
        searchSummary(
            channel: criteria.channelId, sender: criteria.senderId,
            filters: SearchFilters(
                kind: criteria.kind.map { .init(rawValue: $0.rawValue) }, question: criteria.question,
                repository: criteria.repository, since: criteria.since,
                status: criteria.status.map { .init(rawValue: $0.rawValue) }, until: criteria.until),
            model: model)
    }
}

/// The filters past where and from whom, in a popover from the search sheet's filter bar: each change searches again. Days are the
/// person's own: a start is the beginning of its day, and an end is the beginning of the day it names, which is left out.
struct SearchFiltersPopover: View {
    let model: AppModel
    let apply: (SearchFilters) -> Void
    private var filters: SearchFilters { model.searchFilters }
    @State private var repository = ""

    private func change(_ edit: (inout SearchFilters) -> Void) {
        var next = filters
        edit(&next)
        apply(next)
    }

    private static func day(_ date: Date) -> Timestamp { Timestamp(Calendar.current.startOfDay(for: date)) }

    private static func day(after date: Date) -> Timestamp {
        let start = Calendar.current.startOfDay(for: date)
        return Timestamp(Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    var body: some View {
        Form {
            Picker(
                "Thread status",
                selection: Binding(get: { filters.status }, set: { status in change { $0.status = status } })
            ) {
                Text("Any status").tag(nil as SearchFilters.Status?)
                Text("Open").tag(Optional(SearchFilters.Status.open))
                Text("Resolved").tag(Optional(SearchFilters.Status.resolved))
            }
            Picker(
                "Content", selection: Binding(get: { filters.kind }, set: { kind in change { $0.kind = kind } })
            ) {
                Text("Any content").tag(nil as SearchFilters.Kind?)
                Text("Contains code").tag(Optional(SearchFilters.Kind.code))
                Text("Has attachments").tag(Optional(SearchFilters.Kind.file))
            }
            Toggle(
                "Marked questions only",
                isOn: Binding(
                    get: { filters.question != nil },
                    set: { on in change { $0.question = on ? SearchFilters.questionsOnly : nil } }))
            TextField("GitHub repository", text: $repository, prompt: Text("owner/name"))
                .onSubmit(commitRepository)
            Section {
                Toggle(
                    "From",
                    isOn: Binding(
                        get: { filters.since != nil },
                        set: { on in
                            change {
                                $0.since =
                                    on
                                    ? Self.day(Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now) : nil
                            }
                        }))
                if let since = filters.since {
                    DatePicker(
                        "From",
                        selection: Binding(get: { since.date }, set: { date in change { $0.since = Self.day(date) } }),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                }
                Toggle(
                    "Before",
                    isOn: Binding(
                        get: { filters.until != nil },
                        set: { on in change { $0.until = on ? Self.day(after: .now) : nil } }))
                if let until = filters.until {
                    DatePicker(
                        "Before",
                        selection: Binding(get: { until.date }, set: { date in change { $0.until = Self.day(date) } }),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                }
            } footer: {
                if filters.rangeIsInverted {
                    Text("The end date must come after the start date.").foregroundStyle(.red)
                } else {
                    Text("Days are in your time zone; the end date is excluded.").foregroundStyle(.secondary)
                }
            }
            Button("Clear Filters") {
                repository = ""
                apply(SearchFilters())
            }
            .disabled(filters.isEmpty)
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .onAppear { repository = filters.repository ?? "" }
        .onDisappear(perform: commitRepository)
    }

    private func commitRepository() {
        let typed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != (filters.repository ?? "") else { return }
        change { $0.repository = typed.isEmpty ? nil : typed }
    }
}
