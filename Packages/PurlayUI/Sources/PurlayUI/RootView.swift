import PurlayKit
import PurlayTokens
import SwiftUI

/// The window's content: one screen for each phase the model can be in, and no other.
public struct RootView: View {
    private let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) {
        self.model = model
    }

    /// The phase as a plain value, without what a problem carries, so a new problem does not replay the fade.
    private var phaseKey: Int {
        switch model.phase {
        case .launching, .checking: 0
        case .needsServer: 1
        case .problem: 2
        case .signedOut, .signingIn: 3
        case .loading: 4
        case .ready: 5
        }
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .launching, .checking: CheckingView(label: String(localized: "Connecting…"))
            case .needsServer: ServerAddressView(model: model)
            case .problem(let problem): ProblemView(model: model, problem: problem)
            case .signedOut: SignInView(model: model, busy: false)
            case .signingIn: SignInView(model: model, busy: true)
            case .loading: CheckingView(label: String(localized: "Loading your workspace…"))
            case .ready:
                if model.chatAvailable { MainView(model: model) } else { ChatOffView(model: model) }
            }
        }
        .transition(.opacity)
        // Each phase fades into the next instead of cutting: connecting, signing in, loading, the workspace.
        .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationStep), value: phaseKey)
        .frame(minWidth: 640, minHeight: 420)
        // One accent: the system's prominent buttons, selections and toggles take the brand's blue, as the token views do.
        .tint(Colors.accent.color)
        .modifier(AppearancePreference())
        .focusedSceneValue(\.purlayModel, model)
    }
}

/// A workspace without chat still offers its core settings and administration pages.
struct ChatOffView: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Chat Isn’t Turned On", systemImage: "bubble.left.and.exclamationmark.bubble.right")
        } description: {
            Text(
                "This workspace doesn’t have chat. Ask whoever runs the server to turn it on, or open the workspace in your browser."
            )
        } actions: {
            VStack(spacing: Spacing.space2) {
                ForEach(
                    model.availableSettingsPages.filter {
                        [.profile, .workspace, .members, .invitations, .data].contains($0)
                    }
                ) { page in
                    if let destination = page.webPage, let url = model.webURL(destination) {
                        Button {
                            openURL(url)
                        } label: {
                            Label(page.title, systemImage: page.image)
                        }
                    }
                }
            }
            Button("Sign Out") { Task { await model.signOut(.thisDevice) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePalette.canvas.style)
    }
}
