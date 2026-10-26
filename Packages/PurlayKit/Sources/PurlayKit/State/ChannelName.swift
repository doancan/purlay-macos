import Foundation

/// A channel's name as the contract and the sidebar want it: lowercase letters, numbers and hyphens, starting with a letter or a number,
/// at most 64 (D-123). People type names the way they say them ("Genel Sohbet", "İstanbul Ekibi"), so what is typed is turned into that form
/// rather than refused after the fact. Accents and the Turkish letters fold to their plain letter, the dotless ı is spelled, and anything
/// else that is not a letter or a number becomes one hyphen. Ported from the web's `channel-name.ts`.
public enum ChannelName {
    public static let maxLength = 64

    /// The rule, once: what the server is sent and what a field checks before it does.
    public static func isValid(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= maxLength else { return false }
        func plain(_ scalar: Unicode.Scalar) -> Bool {
            (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
        }
        return plain(first) && name.unicodeScalars.allSatisfy { plain($0) || $0 == "-" }
    }

    /// What is typed, as it is typed. A trailing hyphen is kept, or the separator a person has just typed would vanish before the next word.
    public static func typed(_ text: String) -> String {
        var out = ""
        var separating = false
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: break
            }
            let folded = String(scalar).lowercased().replacingOccurrences(of: "ı", with: "i")
            for letter in folded.unicodeScalars {
                let plain =
                    (letter.value >= 0x61 && letter.value <= 0x7A) || (letter.value >= 0x30 && letter.value <= 0x39)
                if plain {
                    out.unicodeScalars.append(letter)
                    separating = false
                } else if !separating, !out.isEmpty {
                    out.append("-")
                    separating = true
                } else if !separating {
                    separating = true
                }
            }
        }
        return String(out.prefix(maxLength))
    }

    /// The name to send: the typed form without a hyphen left at its end, or nil when nothing of it is a name.
    public static func finished(_ text: String) -> String? {
        var name = typed(text)
        while name.hasSuffix("-") { name.removeLast() }
        return isValid(name) ? name : nil
    }
}
