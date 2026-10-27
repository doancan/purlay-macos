import Foundation

// The shapes the generated tokens (Generated/) are written in. No value lives here: every number and colour is generated
// from the server's `tokens.json` (M-5, §6.6), so a change there reaches the app through `scripts/generate` and nowhere else.
// This package depends on nothing and draws nothing: how a token becomes a SwiftUI style, an AppKit colour or a font is
// PurlayUI's `TokenBinding.swift`, the one file allowed to turn a token into something drawn.

/// A colour in sRGB, each component 0…1.
public struct RGBA: Equatable, Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0x2563eb`: how the file writes a colour, three bytes.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255, alpha)
    }

    /// WCAG 2 relative luminance.
    public var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// This colour laid over an opaque one, as the screen shows it.
    public func over(_ base: RGBA) -> RGBA {
        RGBA(
            red * alpha + base.red * (1 - alpha), green * alpha + base.green * (1 - alpha),
            blue * alpha + base.blue * (1 - alpha), 1)
    }

    /// WCAG 2 contrast ratio of two colours, from 1 to 21.
    public static func contrast(_ one: RGBA, _ other: RGBA) -> Double {
        let (lighter, darker) = (max(one.luminance, other.luminance), min(one.luminance, other.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// The appearances a colour is drawn in. Midnight is generated and kept, and not offered (M-6).
public enum Appearance: Sendable, CaseIterable {
    case light, dark
}

/// A named colour with a value for each theme.
public struct TokenColor: Hashable, Sendable {
    public let name: String
    public let light: RGBA
    public let dark: RGBA
    public let midnight: RGBA

    public init(name: String, light: RGBA, dark: RGBA, midnight: RGBA) {
        self.name = name
        self.light = light
        self.dark = dark
        self.midnight = midnight
    }

    public func value(in appearance: Appearance) -> RGBA {
        switch appearance {
        case .light: light
        case .dark: dark
        }
    }
}

/// A step on the type scale. Leading is a multiple of the size and tracking a fraction of it, as CSS writes them; the weight
/// is CSS's 100…900.
public struct TypeStyle: Hashable, Sendable {
    public enum Family: Sendable { case sans, mono }

    public let name: String
    public let family: Family
    public let size: Double
    public let lineHeight: Double
    public let weight: Int
    public let tracking: Double

    public init(name: String, family: Family, size: Double, lineHeight: Double, weight: Int, tracking: Double) {
        self.name = name
        self.family = family
        self.size = size
        self.lineHeight = lineHeight
        self.weight = weight
        self.tracking = tracking
    }

    /// The height of one line, in points.
    public var lineHeightPoints: Double { size * lineHeight }

    /// Tracking in points.
    public var kerning: Double { size * tracking }
}

/// A CSS `cubic-bezier`, for the few movements there are.
public struct CubicBezier: Hashable, Sendable {
    public let x1: Double
    public let y1: Double
    public let x2: Double
    public let y2: Double

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }
}

/// One appearance's shadow: offset, blur, spread and colour, as CSS writes a box shadow.
public struct ShadowValue: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let blur: Double
    public let spread: Double
    public let colour: RGBA

    public init(x: Double, y: Double, blur: Double, spread: Double, colour: RGBA) {
        self.x = x
        self.y = y
        self.blur = blur
        self.spread = spread
        self.colour = colour
    }
}

public struct TokenShadow: Hashable, Sendable {
    public let name: String
    public let light: ShadowValue
    public let dark: ShadowValue
    public let midnight: ShadowValue

    public init(name: String, light: ShadowValue, dark: ShadowValue, midnight: ShadowValue) {
        self.name = name
        self.light = light
        self.dark = dark
        self.midnight = midnight
    }

    public func value(in appearance: Appearance) -> ShadowValue {
        switch appearance {
        case .light: light
        case .dark: dark
        }
    }
}

/// A foreground and the background it is read on, and the contrast it needs (`pairs.json`).
public struct ContrastPair: Sendable {
    public let foreground: TokenColor
    public let background: TokenColor
    public let minimum: Double
    public let why: String

    public init(foreground: TokenColor, background: TokenColor, minimum: Double, why: String) {
        self.foreground = foreground
        self.background = background
        self.minimum = minimum
        self.why = why
    }

    /// The ratio in one appearance; a translucent foreground is laid over its background first.
    public func ratio(in appearance: Appearance) -> Double {
        let back = background.value(in: appearance)
        return RGBA.contrast(foreground.value(in: appearance).over(back), back)
    }
}
