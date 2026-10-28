import PurlayKit
import PurlayTokens
import SwiftUI

public struct DesktopLinkPresentation: ViewModifier {
    @Bindable private var sessions: DesktopSessions

    public init(sessions: DesktopSessions) { self.sessions = sessions }

    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $sessions.linkEntryOpen) { OpenLinkSheet(sessions: sessions) }
            .alert(
                "Could Not Open Link",
                isPresented: Binding(
                    get: { sessions.linkProblem != nil }, set: { if !$0 { sessions.linkProblem = nil } }
                )
            ) {
                Button("OK", role: .cancel) { sessions.linkProblem = nil }
            } message: {
                switch sessions.linkProblem {
                case .invalid: Text("Use a Purlay channel or message link.")
                case .workspaceUnavailable: Text("This account does not belong to the workspace in the link.")
                case .conversationUnavailable:
                    Text("The conversation or message is unavailable. Check your access to the channel and try again.")
                case nil: Text("")
                }
            }
    }
}

private struct OpenLinkSheet: View {
    let sessions: DesktopSessions
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            SheetHeading(
                title: "Open Purlay Link", subtitle: "Paste a channel or message link to open its conversation.",
                image: "link")
            TextField("Channel or message URL", text: $text)
                .textFieldStyle(.roundedBorder).onSubmit(open)
                .onChange(of: text) { _, _ in invalid = false }
            if invalid {
                Text("Enter a valid Purlay channel or message link.")
                    .font(.callout).foregroundStyle(Colors.dangerText.style)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: open).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.space5)
        .frame(width: Size.sizePalette)
    }

    private func open() {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            ConversationLink.parse(url, allowsLocalHTTP: true) != nil
        else {
            invalid = true
            return
        }
        dismiss()
        Task { await sessions.openLink(url) }
    }
}
