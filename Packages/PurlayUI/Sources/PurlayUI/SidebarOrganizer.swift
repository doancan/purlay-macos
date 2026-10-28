import PurlayKit
import PurlayTokens
import SwiftUI

struct SidebarOrganizer: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var editing: UUID?
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            SheetHeading(
                title: "Organize Sidebar", subtitle: "Keep related conversations together on this Mac.",
                image: "sidebar.left")
            HStack {
                TextField(editing == nil ? "New group name" : "Group name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .onChange(of: name) { _, _ in invalid = false }
                Button(editing == nil ? "Add Group" : "Save", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if editing != nil {
                    Button("Cancel Rename") {
                        editing = nil
                        name = ""
                        invalid = false
                    }
                }
            }
            if invalid {
                Text("Use a unique group name of 1–60 characters.")
                    .font(.callout).foregroundStyle(Colors.dangerText.style)
            }
            List {
                ForEach(Array(model.sidebar.enumerated()), id: \.element.id) { index, section in
                    HStack(spacing: Spacing.space2) {
                        VStack(alignment: .leading) {
                            Text(Words.header(section.kind)).fontWeight(.medium)
                            Text("\(section.channels.count) conversations").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if case .custom(let id, let name) = section.kind {
                            Button("Rename \(name)", systemImage: "pencil") {
                                editing = id
                                self.name = name
                                invalid = false
                            }
                            .labelStyle(.iconOnly)
                            Button("Remove Group \(name)", systemImage: "trash", role: .destructive) {
                                model.removeSidebarGroup(id)
                                if editing == id {
                                    editing = nil
                                    self.name = ""
                                }
                            }
                            .labelStyle(.iconOnly)
                            .help("Remove the group and return its conversations to their default sections")
                        }
                        Button("Move \(Words.header(section.kind)) Up", systemImage: "arrow.up") {
                            model.moveSidebarSection(section.id, by: -1)
                        }
                        .labelStyle(.iconOnly).disabled(index == 0)
                        Button("Move \(Words.header(section.kind)) Down", systemImage: "arrow.down") {
                            model.moveSidebarSection(section.id, by: 1)
                        }
                        .labelStyle(.iconOnly).disabled(index == model.sidebar.count - 1)
                    }
                    .padding(.vertical, Spacing.space2)
                    .buttonStyle(.borderless)
                }
            }
            Text(
                "Drag conversations within a section to reorder them. Use a conversation’s menu to move it into a group."
            )
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.space5)
        .frame(width: 580, height: 500)
    }

    private func save() {
        if model.saveSidebarGroup(editing, name: name) {
            name = ""
            editing = nil
            invalid = false
        } else {
            invalid = true
        }
    }
}
