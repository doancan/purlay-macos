import Foundation

/// `tokens.json` and `pairs.json` → the Swift `PurlayTokens` is made of (§6.6). Every visual value the content columns draw
/// comes from here; the support types the output names (`TokenColor`, `RGBA`, `TypeStyle`…) are written by hand in the package,
/// and hold no value of their own.
public enum TokenGenerator {
    public static func generate(tokens: Data, pairs: Data, source: String) throws -> [String: String] {
        guard let root = try JSONSerialization.jsonObject(with: tokens) as? JSON else {
            throw GenerationError("tokens.json is not an object")
        }
        guard let pairRoot = try JSONSerialization.jsonObject(with: pairs) as? JSON else {
            throw GenerationError("pairs.json is not an object")
        }
        let header = Generator.header(source: source)
        let colours = try colourTokens(root)
        return [
            "Colors.swift": header + emitColours(colours),
            "Metrics.swift": header + (try emitMetrics(root)),
            "Typography.swift": header + (try emitTypography(root)),
            "Shadows.swift": header + (try emitShadows(root)),
            "Pairs.swift": header + (try emitPairs(pairRoot, known: Set(colours.map(\.name)))),
        ]
    }

    // MARK: Colours

    static let themes = ["light", "dark", "midnight"]

    struct Colour {
        let name: String
        let usage: String
        let values: [String: RGBA]
    }

    /// A colour as the file writes it: three bytes and an opacity, kept exact so the output is the file's to the bit.
    struct RGBA: Equatable {
        let hex: UInt32
        let alpha: Double

        var swift: String {
            let digits = String(hex, radix: 16)
            let padded = String(repeating: "0", count: max(0, 6 - digits.count)) + digits
            return alpha == 1 ? "RGBA(hex: 0x\(padded))" : "RGBA(hex: 0x\(padded), alpha: \(format(alpha)))"
        }
    }

    static func colourTokens(_ root: JSON) throws -> [Colour] {
        guard let colour = root["color"] as? JSON, let list = colour["tokens"] as? [JSON] else {
            throw GenerationError("tokens.json has no color.tokens")
        }
        var raw: [String: [String: String]] = [:]
        var order: [(String, String)] = []
        for token in list {
            guard let name = token["name"] as? String, let value = token["value"] as? [String: String] else {
                throw GenerationError("a colour token has no name or no value by theme")
            }
            raw[name] = value
            order.append((name, token["usage"] as? String ?? ""))
        }
        return try order.map { name, usage in
            var values: [String: RGBA] = [:]
            for theme in themes {
                values[theme] = try resolve(name, theme: theme, in: raw, seen: [])
            }
            return Colour(name: name, usage: usage, values: values)
        }
    }

    /// A value is a hex colour, an `rgba(…)`, or `{other}`: the other token's value in the same theme.
    static func resolve(_ name: String, theme: String, in raw: [String: [String: String]], seen: Set<String>) throws
        -> RGBA
    {
        guard !seen.contains(name) else { throw GenerationError("colour \(name) refers to itself") }
        guard let text = raw[name]?[theme] else { throw GenerationError("colour \(name) has no \(theme) value") }
        if text.hasPrefix("{"), text.hasSuffix("}") {
            return try resolve(String(text.dropFirst().dropLast()), theme: theme, in: raw, seen: seen.union([name]))
        }
        return try parseColour(text, token: name)
    }

    static func parseColour(_ text: String, token: String) throws -> RGBA {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#"), trimmed.count == 7, let value = UInt32(trimmed.dropFirst(), radix: 16) {
            return RGBA(hex: value, alpha: 1)
        }
        if trimmed.hasPrefix("rgba("), trimmed.hasSuffix(")") {
            let parts = trimmed.dropFirst(5).dropLast().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 4, let r = UInt32(parts[0]), let g = UInt32(parts[1]), let b = UInt32(parts[2]),
                r < 256, g < 256, b < 256, let a = Double(parts[3]), (0...1).contains(a)
            {
                return RGBA(hex: r << 16 | g << 8 | b, alpha: a)
            }
        }
        throw GenerationError("colour \(token): \(text) is neither #rrggbb nor rgba(r, g, b, a)")
    }

    static func emitColours(_ colours: [Colour]) -> String {
        var out = "/// The colour tokens, one per name in `tokens.json`, each with its value in every theme.\n"
        out += "public enum Colors {\n"
        for colour in colours {
            out += "    /// \(oneLine(colour.usage))\n"
            out += "    public static let \(identifier(colour.name)) = TokenColor(\n"
            out += "        name: \(quoted(colour.name)),\n"
            for (index, theme) in themes.enumerated() {
                let comma = index == themes.count - 1 ? ")" : ","
                out += "        \(theme): \(colour.values[theme]?.swift ?? "")\(comma)\n"
            }
        }
        out += "\n    /// Every colour, in the file's order: what a test compares the vocabulary against.\n"
        out += "    public static let all: [TokenColor] = [\n"
        out += colours.map { "        \(identifier($0.name)),\n" }.joined()
        out += "    ]\n}\n"
        return out
    }

    // MARK: Metrics

    static func emitMetrics(_ root: JSON) throws -> String {
        var out = ""
        let groups: [(key: String, type: String, doc: String)] = [
            ("spacing", "Spacing", "Steps of space between and inside things, in points."),
            ("radius", "Radius", "Corner radii, in points."),
            ("size", "Size", "Fixed sizes: columns, controls, avatars, icons, in points."),
            ("borderWidth", "Stroke", "Line widths, in points."),
        ]
        for group in groups {
            let list = try tokens(root, group.key)
            out += "/// \(group.doc)\npublic enum \(group.type) {\n"
            for token in list {
                let name = try string(token, "name")
                let value = try points(try string(token, "value"), token: name)
                out += usageComment(token)
                out += "    public static let \(identifier(name)): Double = \(format(value))\n"
            }
            out +=
                "\n    public static let names: [String] = [\(list.compactMap { $0["name"] as? String }.map(quoted).joined(separator: ", "))]\n"
            out += "}\n\n"
        }

        let durations = try tokens(root, "duration")
        out += "/// How long the few movements last (UX §9: motion is almost absent, and none under Reduce Motion).\n"
        out += "public enum Motion {\n"
        for token in durations {
            let name = try string(token, "name")
            let text = try string(token, "value")
            guard text.hasSuffix("ms"), let milliseconds = Int(text.dropLast(2)) else {
                throw GenerationError("duration \(name): \(text) is not a whole number of ms")
            }
            out += usageComment(token)
            out += "    public static let \(identifier(name)): Duration = .milliseconds(\(milliseconds))\n"
        }
        let easings = try tokens(root, "easing")
        for token in easings {
            let name = try string(token, "name")
            let text = try string(token, "value")
            let numbers = text.replacingOccurrences(of: "cubic-bezier(", with: "").replacingOccurrences(
                of: ")", with: ""
            )
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard text.hasPrefix("cubic-bezier("), numbers.count == 4 else {
                throw GenerationError("easing \(name): \(text) is not a cubic-bezier of four numbers")
            }
            out += usageComment(token)
            out +=
                "    public static let \(identifier(name)) = CubicBezier(\(numbers.map(format).joined(separator: ", ")))\n"
        }
        let names = (durations + easings).compactMap { $0["name"] as? String }
        out += "\n    public static let names: [String] = [\(names.map(quoted).joined(separator: ", "))]\n}\n"
        return out
    }

    // MARK: Typography

    static func emitTypography(_ root: JSON) throws -> String {
        guard let type = root["type"] as? JSON, let groups = type["groups"] as? [JSON] else {
            throw GenerationError("tokens.json has no type.groups")
        }
        var out =
            "/// The type scale. The family is the system's (SF, SF Mono for code); size, leading, weight and tracking are the\n"
        out += "/// tokens'.\npublic enum Typography {\n"
        var names: [String] = []
        for group in groups {
            let family = try string(group, "family")
            guard family == "sans" || family == "mono" else { throw GenerationError("unknown type family \(family)") }
            for style in (group["styles"] as? [JSON]) ?? [] {
                let name = try string(style, "name")
                let size = try points(try string(style, "fontSize"), token: name)
                guard let leading = style["lineHeight"] as? Double, let weight = style["fontWeight"] as? Int else {
                    throw GenerationError("type style \(name) has no lineHeight or fontWeight")
                }
                var tracking = 0.0
                if let text = style["letterSpacing"] as? String {
                    guard text.hasSuffix("em"), let em = Double(text.dropLast(2)) else {
                        throw GenerationError("type style \(name): letterSpacing \(text) is not in em")
                    }
                    tracking = em
                }
                names.append(name)
                out += usageComment(style)
                out += "    public static let \(identifier(name)) = TypeStyle(\n"
                out +=
                    "        name: \(quoted(name)), family: .\(family), size: \(format(size)), lineHeight: \(format(leading)), "
                out += "weight: \(weight), tracking: \(format(tracking)))\n"
            }
        }
        out += "\n    public static let all: [TypeStyle] = [\(names.map(identifier).joined(separator: ", "))]\n}\n"
        return out
    }

    // MARK: Shadows

    static func emitShadows(_ root: JSON) throws -> String {
        var out =
            "/// Elevation (D-110): a hairline for a card inside, more for what floats above.\npublic enum Shadows {\n"
        let list = try tokens(root, "shadow")
        for token in list {
            let name = try string(token, "name")
            guard let value = token["value"] as? [String: String] else {
                throw GenerationError("shadow \(name) has no value by theme")
            }
            out += usageComment(token)
            out += "    public static let \(identifier(name)) = TokenShadow(\n        name: \(quoted(name)),\n"
            for (index, theme) in themes.enumerated() {
                guard let text = value[theme] else { throw GenerationError("shadow \(name) has no \(theme) value") }
                let comma = index == themes.count - 1 ? ")" : ","
                out += "        \(theme): \(try shadow(text, token: name))\(comma)\n"
            }
        }
        out +=
            "\n    public static let all: [TokenShadow] = [\(list.compactMap { $0["name"] as? String }.map(identifier).joined(separator: ", "))]\n}\n"
        return out
    }

    /// `x y blur spread rgba(…)`, as CSS writes a box shadow.
    static func shadow(_ text: String, token: String) throws -> String {
        guard let open = text.range(of: "rgba(") else {
            throw GenerationError("shadow \(token): \(text) has no rgba colour")
        }
        let lengths = text[..<open.lowerBound].split(separator: " ").map(String.init)
        guard lengths.count == 4 else {
            throw GenerationError("shadow \(token): \(text) is not x y blur spread colour")
        }
        let numbers = try lengths.map { try points($0, token: token) }
        let colour = try parseColour(String(text[open.lowerBound...]), token: token)
        return "ShadowValue(x: \(format(numbers[0])), y: \(format(numbers[1])), blur: \(format(numbers[2])), "
            + "spread: \(format(numbers[3])), colour: \(colour.swift))"
    }

    // MARK: Pairs

    static func emitPairs(_ root: JSON, known: Set<String>) throws -> String {
        guard let pairs = root["pairs"] as? [JSON] else { throw GenerationError("pairs.json has no pairs") }
        var out =
            "/// The pairs that must be readable, with the contrast each needs in every appearance (`pairs.json`).\n"
        out += "public enum ContrastPairs {\n    public static let all: [ContrastPair] = [\n"
        for pair in pairs {
            let foreground = try string(pair, "foreground")
            let background = try string(pair, "background")
            for name in [foreground, background] where !known.contains(name) {
                throw GenerationError("pairs.json names \(name), which is not a colour token")
            }
            guard let minimum = pair["minimum"] as? Double else { throw GenerationError("a pair has no minimum") }
            out +=
                "        ContrastPair(foreground: Colors.\(identifier(foreground)), background: Colors.\(identifier(background)), "
            out += "minimum: \(format(minimum)), why: \(quoted(pair["why"] as? String ?? ""))),\n"
        }
        out += "    ]\n}\n"
        return out
    }

    // MARK: Reading

    static func tokens(_ root: JSON, _ key: String) throws -> [JSON] {
        guard let group = root[key] as? JSON, let list = group["tokens"] as? [JSON] else {
            throw GenerationError("tokens.json has no \(key).tokens")
        }
        return list
    }

    static func string(_ object: JSON, _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw GenerationError("a token has no \(key)") }
        return value
    }

    /// `12px` → 12, and a bare `0`. A CSS pixel is a point on the Mac.
    static func points(_ text: String, token: String) throws -> Double {
        if text == "0" { return 0 }  // CSS writes a zero length without a unit.
        guard text.hasSuffix("px"), let value = Double(text.dropLast(2)) else {
            throw GenerationError("\(token): \(text) is not in px")
        }
        return value
    }

    // MARK: Writing

    /// `surface-000` → `surface000`, `size-dialog-lg` → `sizeDialogLg`: the token's name, as Swift spells one.
    static func identifier(_ name: String) -> String {
        let parts = name.split(separator: "-").map(String.init)
        guard let first = parts.first else { return name }
        return first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e9 { return String(Int(value)) }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    static func usageComment(_ token: JSON) -> String {
        guard let usage = token["usage"] as? String, !usage.isEmpty else { return "" }
        return "    /// \(oneLine(usage))\n"
    }
}
