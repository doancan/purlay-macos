import PurlayTokens

/// macOS surface roles, in the neutral greys of the system's own apps. The window chrome (sidebar, toolbar, inspector) is the
/// system's glass and draws no palette colour; the brand's blue stays in `Colors.accent`, for what is chosen or acted on.
enum NativePalette {
    static let sidebar = token("sidebar", light: 0xf5f5f7, dark: 0x202022)
    static let canvas = token("canvas", light: 0xffffff, dark: 0x1e1e1e)
    static let raised = token("raised", light: 0xffffff, dark: 0x2a2a2c)
    static let hover = token("hover", light: 0xf9f9fa, dark: 0x2c2c2e)
    static let border = token("border", light: 0xd1d1d6, dark: 0x3a3a3c)
    static let divider = token("divider", light: 0xe5e5ea, dark: 0x38383a)
    static let ink = token("ink", light: 0x1d1d1f, dark: 0xf5f5f7)
    static let secondary = token("secondary", light: 0x6e6e73, dark: 0xa1a1a6)
    /// Third-level text: "edited", a deleted message, a count, the typing dots. Readable, but below `secondary`.
    static let tertiary = token("tertiary", light: 0x747478, dark: 0x99999f)
    /// A quiet fill a step off the canvas, lighter than it in dark: chips, cards, placeholders (quaternarySystemFill).
    static let fill = token("fill", light: 0xf2f2f4, dark: 0x2e2e30)
    /// What is chosen or marked, tinted from the accent on a neutral base: a search hit, the person's own reaction.
    static let selection = token("selection", light: 0xe8f0fe, dark: 0x1f2a3d)
    /// The chosen pill of a segmented row, as the system's own knob: white in light, a lifted grey in dark.
    static let segmentKnob = token("segment-knob", light: 0xffffff, dark: 0x5a5a5e)
    // The system's own status colours (systemGreen, systemRed, systemOrange), for marks rather than text.
    static let success = token("success", light: 0x28cd41, dark: 0x32d74b)
    static let danger = token("danger", light: 0xff3b30, dark: 0xff453a)
    static let warning = token("warning", light: 0xff9500, dark: 0xff9f0a)
    // Code: a block is a quiet well a step off the canvas; inline code a chip a step further, so it reads inside a sentence.
    static let codeSurface = token("code-surface", light: 0xf5f5f7, dark: 0x252527)
    static let codeChip = token("code-chip", light: 0xebebee, dark: 0x343437)

    /// Brand colour for primary actions, separate from neutral window chrome.
    static let brand = token("brand", light: 0x015bf7, dark: 0x5b96ff)

    private static func token(_ name: String, light: UInt32, dark: UInt32) -> TokenColor {
        TokenColor(name: "mac-\(name)", light: RGBA(hex: light), dark: RGBA(hex: dark), midnight: RGBA(hex: dark))
    }
}
