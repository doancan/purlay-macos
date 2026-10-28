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
                .background(NativePalette.raised.style, in: .rect(cornerRadius: radius))
                .overlay {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(NativePalette.border.style)
                }
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        }
    }
}

struct WindowHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Semantic styles: on the toolbar's glass the system gives them vibrancy, as it does a window's own title.
            Text(title).font(.headline).foregroundStyle(.primary)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: Size.sizeAttachment, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
