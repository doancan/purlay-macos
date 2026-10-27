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
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Custom glass has an opaque equivalent when Reduce Transparency is enabled.
struct ControlSurface: ViewModifier {
    var radius: Double = Radius.radius2xl
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Colors.surface100.style, in: .rect(cornerRadius: radius))
                .overlay {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(Colors.borderSubtle.style)
                }
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        }
    }
}

/// Samples the desktop behind the window instead of tinting the sidebar with the content's grey background.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = SidebarEffectView()
        view.blendingMode = .behindWindow
        view.material = .sidebar
        view.state = .followsWindowActiveState
        return view
    }

    // AppKit owns the material's layers and active state; scrolling never rebuilds that compositing surface.
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct SidebarSurface: View {
    @AppStorage("sidebar.translucent") private var translucent = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if translucent && !reduceTransparency {
            SidebarMaterial()
                .overlay(NativePalette.sidebarWash.color.opacity(0.18))
        } else {
            NativePalette.sidebarSolid.color
        }
    }
}

struct WindowHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(NativePalette.onToolbar.style)
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption).foregroundStyle(NativePalette.toolbarDetail.style)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private final class SidebarEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isOpaque = false
        window?.backgroundColor = .clear
    }
}
