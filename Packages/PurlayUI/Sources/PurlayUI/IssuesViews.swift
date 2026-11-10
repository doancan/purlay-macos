import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// The workspace's issues (D-254): open or done, each with a title, who it is given to, and a check to finish it.
struct IssuesPage: View {
    let model: AppModel
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(
                    "Show",
                    selection: Binding(
                        get: { model.issueFilter },
                        set: { filter in Task { await model.setIssueFilter(filter) } })
                ) {
                    Text("Open").tag(IssueFilter.open)
                    Text("Done").tag(IssueFilter.done)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("New Issue", systemImage: "plus") { creating = true }
                    .keyboardShortcut("n", modifiers: [.command, .control])
            }
            .padding(Spacing.space4)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(NativePalette.canvas.style)
        .navigationTitle("Issues")
        .navigationSubtitle(model.issueFilter == .open ? String(localized: "Open") : String(localized: "Done"))
        .sheet(isPresented: $creating) { NewIssueSheet(model: model) }
    }

    @ViewBuilder private var content: some View {
        switch model.issuesStatus {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case .failed:
            ContentUnavailableView {
                Label("Could Not Load Issues", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await model.reloadIssues() } }.buttonStyle(.glassProminent)
            }
        case .loaded:
            if model.issueItems.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.issueFilter == .open ? "No Open Issues" : "No Finished Issues", systemImage: "checklist")
                } description: {
                    Text(
                        model.issueFilter == .open
                            ? "Make an issue to keep track of something that needs doing."
                            : "Issues you finish are kept here.")
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.issueItems, id: \.id) { issue in IssueRow(model: model, issue: issue) }
                if model.issuesHaveMore {
                    Button {
                        Task { await model.loadMoreIssues() }
                    } label: {
                        HStack {
                            if model.issuesLoadingMore { ProgressView().controlSize(.small) }
                            Text(model.issuesLoadingMore ? "Loading…" : "Load More")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(model.issuesLoadingMore)
                    .padding(Spacing.space4)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: Size.sizeFeedMax)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct IssueRow: View {
    let model: AppModel
    let issue: Issue
    @State private var hovering = false
    @State private var confirmingDelete = false

    private var done: Bool { issue.status == .done }
    private var assignee: User? { issue.assigneeId.flatMap { model.person($0) } }
    private var mine: Bool { issue.createdBy == model.me?.user.id }
    private var mayDelete: Bool {
        guard mine else {
            let role = model.me?.memberships.first { $0.workspace.id == model.workspace?.id }?.role
            return role == .owner || role == .admin
        }
        return true
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
            Button {
                Task { await model.setIssueStatus(issue, done ? .open : .done) }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(done ? Colors.success.style : NativePalette.secondary.style)
            }
            .buttonStyle(.plain)
            .help(done ? "Reopen" : "Mark Done")
            .accessibilityLabel(done ? "Reopen \(issue.title)" : "Mark \(issue.title) done")
            VStack(alignment: .leading, spacing: Stroke.strokeFocus) {
                Text(issue.title)
                    .typeStyle(Typography.body)
                    .strikethrough(done)
                    .foregroundStyle(done ? NativePalette.secondary.style : NativePalette.ink.style)
                    .lineLimit(2)
                if !issue.body.isEmpty {
                    Text(issue.body).typeStyle(Typography.caption).foregroundStyle(NativePalette.secondary.style)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: Spacing.space2)
            if let assignee {
                Label(assignee.displayName, systemImage: "person.crop.circle")
                    .typeStyle(Typography.caption)
                    .foregroundStyle(NativePalette.secondary.style)
            }
        }
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space3)
        .background(hovering ? NativePalette.hover.style : NativePalette.canvas.style)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NativePalette.divider.style).frame(height: Stroke.strokeHairline)
        }
        .onContinuousHover { phase in
            if case .active = phase { hovering = true } else { hovering = false }
        }
        .contextMenu {
            Menu("Assign To", systemImage: "person") {
                Button("Nobody") { Task { await model.assignIssue(issue, to: nil) } }
                ForEach(model.workspacePeople, id: \.id) { person in
                    Button(person.displayName) { Task { await model.assignIssue(issue, to: person.id) } }
                }
            }
            if mayDelete {
                Button("Delete Issue", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(done ? "Reopen" : "Mark Done")) {
            Task { await model.setIssueStatus(issue, done ? .open : .done) }
        }
        .accessibilityAction(named: Text("Assign To Nobody")) { Task { await model.assignIssue(issue, to: nil) } }
        .accessibilityAction(named: Text("Delete Issue")) {
            if mayDelete { confirmingDelete = true }
        }
        .confirmationDialog("Delete this issue?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Issue", role: .destructive) { Task { await model.deleteIssue(issue) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(issue.title)” is removed for everybody in the workspace. This can’t be undone.")
        }
    }
}

private struct NewIssueSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var assignee: Uuid?
    @State private var saving = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            SheetHeading(title: "New Issue", subtitle: "Something that needs doing.", image: "checklist")
            TextField("Title", text: $title).textFieldStyle(.roundedBorder).onSubmit(save)
            TextEditor(text: $details)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(NativePalette.divider.style))
                .accessibilityLabel("Details")
            Picker("Give it to", selection: $assignee) {
                Text("Nobody").tag(nil as Uuid?)
                ForEach(model.workspacePeople, id: \.id) { person in
                    Text(person.displayName).tag(Optional(person.id))
                }
            }
            if failed {
                Text("Could not make the issue. Check the title and try again.")
                    .font(.callout).foregroundStyle(Colors.dangerText.style)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Make Issue", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.space5)
        .frame(width: 460)
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            if await model.createIssue(title: title, details: details, assignee: assignee) {
                dismiss()
            } else {
                failed = true
                saving = false
            }
        }
    }
}
