import PurlayKit
import PurlayTokens
import SwiftUI

/// The window's content: one screen for each phase the model can be in, and no other.
public struct RootView: View {
    private let model: AppModel
    @AppStorage("appearance") private var appearance = AppAppearance.system

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
            case .ready: MainView(model: model)
            }
        }
        .transition(.opacity)
        // Each phase fades into the next instead of cutting: connecting, signing in, loading, the workspace.
        .animation(Motion.easingStandard.animation(Motion.durationStep), value: phaseKey)
        .frame(minWidth: 520, minHeight: 360)
        // One accent: the system's prominent buttons, selections and toggles take the brand's blue, as the token views do.
        .tint(Colors.accent.color)
        .preferredColorScheme(appearance.scheme)
        .focusedSceneValue(\.purlayModel, model)
    }
}
