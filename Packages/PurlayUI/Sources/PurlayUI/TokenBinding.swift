import AppKit
import PurlayTokens
import SwiftUI

// The one place a token becomes something drawn (§6.6, §16.2): a SwiftUI style, an AppKit colour, a font, an animation. A
// view elsewhere names tokens and never a colour or a number of its own; the source scan in scripts/enforcement allows the
// literals this file needs and refuses them everywhere else.

/// A colour token as SwiftUI draws it: `.foregroundStyle(Colors.ink.style)` takes the light value in light and the dark
/// value in dark. A wrapper rather than a conformance of `TokenColor`, which is another module's type.
public struct TokenStyle: ShapeStyle {
    public let token: TokenColor

    public func resolve(in environment: EnvironmentValues) -> Color.Resolved {
        token.value(in: environment.colorScheme == .dark ? .dark : .light).resolved
    }
}

extension TokenColor {
    /// This colour as a SwiftUI style.
    public var style: TokenStyle { TokenStyle(token: self) }

    /// The same colour for AppKit: it follows the appearance of whatever draws it.
    public var nsColor: NSColor {
        let light = light.nsColor
        let dark = dark.nsColor
        return NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// For the places SwiftUI asks for a `Color` rather than a style.
    public var color: Color { Color(nsColor: nsColor) }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    var resolved: Color.Resolved {
        Color.Resolved(
            colorSpace: .sRGB, red: Float(red), green: Float(green), blue: Float(blue), opacity: Float(alpha))
    }
}

extension TypeStyle {
    public var fontWeight: Font.Weight {
        switch weight {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
    }

    var nsFontWeight: NSFont.Weight {
        switch weight {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
    }

    /// The system face (SF, or SF Mono for code) at this size and weight.
    public var font: Font {
        .system(size: size, weight: fontWeight, design: family == .mono ? .monospaced : .default)
    }

    public var nsFont: NSFont {
        family == .mono
            ? .monospacedSystemFont(ofSize: size, weight: nsFontWeight)
            : .systemFont(ofSize: size, weight: nsFontWeight)
    }

    /// Space added between lines so a line is the style's height, as on the web.
    public var lineSpacing: Double {
        max(0, lineHeightPoints - (nsFont.ascender - nsFont.descender + nsFont.leading))
    }
}

extension CubicBezier {
    public func animation(_ duration: Duration) -> Animation {
        .timingCurve(x1, y1, x2, y2, duration: duration.seconds)
    }
}

extension Duration {
    /// A token duration as the seconds an `Animation` takes.
    public var seconds: Double {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

extension View {
    /// Text in a token style: its face, its tracking, and the line height the web gives it.
    public func typeStyle(_ style: TypeStyle) -> some View {
        font(style.font).tracking(style.kerning).lineSpacing(style.lineSpacing)
    }

    /// A token shadow, in the appearance the view is drawn in.
    public func tokenShadow(_ shadow: TokenShadow) -> some View {
        modifier(TokenShadowModifier(shadow: shadow))
    }
}

private struct TokenShadowModifier: ViewModifier {
    let shadow: TokenShadow
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let value = shadow.value(in: scheme == .dark ? .dark : .light)
        // CSS's blur is twice SwiftUI's radius; spread has no SwiftUI counterpart and the tokens use none.
        content.shadow(color: value.colour.color, radius: value.blur / 2, x: value.x, y: value.y)
    }
}

extension RGBA {
    fileprivate var color: Color { Color(nsColor: nsColor) }
}
