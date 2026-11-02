import AppKit
import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// What the server says of the account itself (`GET /api/me`), as bars above the conversation that stay until it is no longer
/// true: two-step verification it requires (D-239), and workspaces of the person's that are about to be erased (D-242). Neither
/// is done here; each bar opens the browser, where it is.
struct AccountNoticeBars: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            if model.mustEnrolTwoFactor {
                bar(
                    Text(
                        "This server requires two-step verification. Turn it on in your browser to keep using Purlay."),
                    symbol: "lock.shield", tint: Colors.warningText.style
                ) {
                    Button("Set Up in Browser") { if let url = model.twoFactorSetupURL { openURL(url) } }
                        .disabled(model.twoFactorSetupURL == nil)
                    Button("Check Again") { Task { await model.refreshAccount() } }
                }
                // Back from the browser: read whether it is on now.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await model.refreshAccount() }
                }
            }
            ForEach(model.scheduledDeletions, id: \.workspace.id) { deletion in
                bar(
                    Text(
                        "\(deletion.workspace.name) is being deleted. Everything in it will be erased on \(deletion.purgeAt.date.formatted(date: .long, time: .shortened))."
                    ),
                    symbol: "trash", tint: Colors.dangerText.style
                ) {
                    Button("Keep Workspace in Browser…") { if let url = model.webFrontDoor { openURL(url) } }
                        .disabled(model.webFrontDoor == nil)
                        .help("An owner can cancel the deletion from the browser until then.")
                }
            }
        }
    }

    private func bar<Actions: View>(
        _ text: Text, symbol: String, tint: TokenStyle, @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Image(systemName: symbol).foregroundStyle(tint)
            text.font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.space2)
            actions().buttonStyle(.link)
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

/// The window's place while the account is held back for two-step verification: nothing else can be read until it is on.
struct TwoFactorRequiredView: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Two-Step Verification Required", systemImage: "lock.shield")
        } description: {
            Text(
                "This server asks everyone who signs in with a password to turn on two-step verification. Set it up in your browser, then come back."
            )
        } actions: {
            Button("Set Up in Browser") { if let url = model.twoFactorSetupURL { openURL(url) } }
                .buttonStyle(.glassProminent)
                .disabled(model.twoFactorSetupURL == nil)
            Button("Check Again") { Task { await model.refreshAccount() } }.buttonStyle(.glass)
        }
    }
}
