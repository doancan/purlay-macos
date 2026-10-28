import AppKit
import PurlayTokens
import SwiftUI

/// Local presentation preferences, shared by every window and the Settings scene.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var native: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// A transient control surface, with an opaque, outlined equivalent for accessibility settings.
struct ControlSurface: ViewModifier {
    var radius: Double = Radius.radius2xl
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: radius))
                .overlay {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(
                            Color.primary.opacity(contrast == .increased ? 0.6 : 0.2),
                            lineWidth: contrast == .increased ? Stroke.strokeFocus : Stroke.strokeHairline
                        )
                        .allowsHitTesting(false)
                }
        } else {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: radius))
        }
    }
}

/// Native sidebar material by default. The local preference can opt out, as can Reduce Transparency.
/// Never mutate the containing window's opacity or layer a second blur over the system sidebar.
struct SidebarSurface: ViewModifier {
    @AppStorage("sidebar.translucent") private var translucent = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var opaque: Bool { !translucent || reduceTransparency }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(opaque ? .hidden : .automatic)
            .background {
                if opaque { NativePalette.sidebar.color.ignoresSafeArea() }
            }
    }
}
