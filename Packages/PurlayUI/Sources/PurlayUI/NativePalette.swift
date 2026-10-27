import PurlayTokens

/// macOS surface roles. The reading canvas, elevated controls and branded window chrome have distinct values.
enum NativePalette {
    static let canvas = token("canvas", light: 0xffffff, dark: 0x111a28)
    static let raised = token("raised", light: 0xffffff, dark: 0x1b293d)
    static let hover = token("hover", light: 0xdce7f6, dark: 0x243751)
    static let border = token("border", light: 0xb6c6dd, dark: 0x4c6483)
    static let divider = token("divider", light: 0xcbd7e8, dark: 0x32465f)
    static let ink = token("ink", light: 0x17263e, dark: 0xf0f5fc)
    static let secondary = token("secondary", light: 0x41536f, dark: 0xb7c9e2)
    // Sampled from the logo's dominant blue (#015BF7).
    static let toolbar = token("toolbar", light: 0x015bf7, dark: 0x0646be)
    static let onToolbar = token("on-toolbar", light: 0xffffff, dark: 0xffffff)
    static let toolbarDetail = token("toolbar-detail", light: 0xe7efff, dark: 0xe7efff)
    static let toolbarControl = token("toolbar-control", light: 0x173866, dark: 0xf0f5fc)
    static let sidebarSolid = token("sidebar-solid", light: 0xf1f2f4, dark: 0x1c2028)
    static let sidebarWash = token("sidebar-wash", light: 0xeef0f3, dark: 0x20262e)

    private static func token(_ name: String, light: UInt32, dark: UInt32) -> TokenColor {
        TokenColor(name: "mac-\(name)", light: RGBA(hex: light), dark: RGBA(hex: dark), midnight: RGBA(hex: dark))
    }
}
