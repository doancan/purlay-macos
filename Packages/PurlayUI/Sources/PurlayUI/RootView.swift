import PurlayKit
import SwiftUI

/// The window's content: one screen for each phase the model can be in, and no other.
public struct RootView: View {
    private let model: AppModel
    @AppStorage("appearance") private var appearance = AppAppearance.system

    public init(model: AppModel) {
        self.model = model
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
        .frame(minWidth: 520, minHeight: 360)
        .preferredColorScheme(appearance.scheme)
    }
}
