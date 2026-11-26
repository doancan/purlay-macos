import AppKit
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
        case .launching, .checking, .loading: 0
        case .problem: 2
        case .signedOut, .signingIn: 3
        case .ready: 5
        }
    }

    /// What the window says while it waits, or nil when there is a screen to show.
    private var waitingLabel: String? {
        switch model.phase {
        case .launching, .checking: String(localized: "Connecting…")
        case .loading: String(localized: "Loading your workspace…")
        default: nil
        }
    }

    @ViewBuilder private var screen: some View {
        switch model.phase {
        case .launching, .checking, .loading: EmptyView()
        case .problem(let problem): ProblemView(model: model, problem: problem)
        case .signedOut: SignInView(model: model, busy: false)
        case .signingIn: SignInView(model: model, busy: true)
        case .ready:
            if model.chatAvailable { MainView(model: model) } else { ChatOffView(model: model) }
        }
    }

    public var body: some View {
        Group {
            // Connecting and loading are one wait, so they are one view: the icon keeps breathing and only the words change.
            if let wait = waitingLabel {
                LaunchView(label: wait)
            } else {
                screen
            }
        }
        .transition(.opacity)
        // Each phase fades into the next instead of cutting: connecting, signing in, loading, the workspace.
        .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationStep), value: phaseKey)
        .frame(minWidth: 640, minHeight: 420)
        // One accent: the system's prominent buttons, selections and toggles take the brand's blue, as the token views do.
        .tint(Colors.accent.color)
        .modifier(AppearancePreference())
        .modifier(ActivityReporter(model: model))
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
                        .glassButton(prominent: page == .workspace)
                    }
                }
            }
            Button("Sign Out") { Task { await model.signOut(.thisDevice) } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NativePalette.canvas.style)
    }
}

/// Tells the model when the person uses the app (D-143, D-257): a key, a click, a moving pointer, the wheel. Only this app's events
/// are seen, and the model listens only while its own window is in front; the engine rations what reaches the server to one word a
/// minute. A window left open on a desk says nothing, so the person shows as away after `AWAY_AFTER_MS`.
private struct ActivityReporter: ViewModifier {
    let model: AppModel
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .scrollWheel]
                ) { [model] event in
                    MainActor.assumeIsolated { model.noteActivity() }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
