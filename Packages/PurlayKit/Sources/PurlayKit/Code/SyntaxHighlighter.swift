import Foundation

/// What a run of code is, as far as colour is concerned. The colours are the design tokens' (`syntax-*`); this knows none.
public enum SyntaxKind: Sendable, Equatable {
    case plain, keyword, string, number, comment, function, type, `operator`
    /// A line a diff adds or removes, and the line that says where.
    case added, removed, hunk
}

public struct SyntaxToken: Sendable, Equatable {
    public let kind: SyntaxKind
    public let text: String
}

/// Syntax colouring without a grammar engine: a scanner that knows a language by its comments, its strings, its keywords and its
/// numbers, which is what carries a chat message's snippet. It never fails: a language it does not know, or a block too long to be worth
/// colouring, comes back as plain text with the same layout, so nothing moves when it does or does not colour.
public enum SyntaxHighlighter {
    /// Past this many characters colouring would cost the feed more than it gives the reader.
    public static let limit = 24_000

    public static func tokens(_ code: String, language: String?) -> [SyntaxToken] {
        guard code.count <= limit, let name = language.map(normalised) else {
            return [SyntaxToken(kind: .plain, text: code)]
        }
        if name == "diff" { return diff(code) }
        guard let profile = Profile.all[name] else { return [SyntaxToken(kind: .plain, text: code)] }
        var scanner = Scanner(profile: profile, chars: Array(code))
        return scanner.run()
    }

    static func normalised(_ language: String) -> String {
        let name = language.lowercased().trimmingCharacters(in: .whitespaces)
        return aliases[name] ?? name
    }

    private static let aliases: [String: String] = [
        "ts": "typescript", "tsx": "typescript", "js": "javascript", "jsx": "javascript", "mjs": "javascript",
        "py": "python", "rs": "rust", "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash",
        "yml": "yaml", "golang": "go", "kt": "kotlin", "rb": "ruby", "c++": "cpp", "cc": "cpp", "h": "c",
        "cs": "csharp", "html": "xml", "svg": "xml", "scss": "css", "patch": "diff", "jsonc": "json",
    ]

    // MARK: Diff

    private static func diff(_ code: String) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let kind: SyntaxKind
            if line.hasPrefix("@@") {
                kind = .hunk
            } else if line.hasPrefix("+++") || line.hasPrefix("---") {
                kind = .function
            } else if line.hasPrefix("+") {
                kind = .added
            } else if line.hasPrefix("-") {
                kind = .removed
            } else {
                kind = .plain
            }
            out.append(SyntaxToken(kind: kind, text: String(line) + (index < lines.count - 1 ? "\n" : "")))
        }
        return out
    }

    // MARK: Languages

    struct Profile {
        var keywords: Set<String>
        var lineComments: [String] = ["//"]
        var block: (String, String)? = ("/*", "*/")
        var quotes: Set<Character> = ["\"", "'"]
        var backtick = false
        /// A word before `(` is a function; a capitalised word is a type.
        var calls = true

        static let c: Set<String> = [
            "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto",
            "typedef", "struct",
            "enum", "union", "static", "const", "extern", "sizeof", "void", "int", "char", "long", "short", "float",
            "double", "unsigned",
            "signed", "bool", "true", "false", "null", "nullptr", "class", "public", "private", "protected", "new",
            "delete", "namespace",
            "using", "template", "typename", "virtual", "override", "inline", "try", "catch", "throw", "this", "auto",
            "nil",
        ]

        static let all: [String: Profile] = [
            "swift": Profile(keywords: [
                "let", "var", "func", "class", "struct", "enum", "protocol", "extension", "import", "return", "if",
                "else", "guard",
                "switch", "case", "default", "for", "in", "while", "repeat", "break", "continue", "do", "try", "catch",
                "throw",
                "throws", "rethrows", "async", "await", "actor", "init", "deinit", "self", "Self", "super", "nil",
                "true", "false", "public",
                "private", "fileprivate", "internal", "open", "static", "final", "override", "mutating", "lazy", "weak",
                "where", "as", "is",
                "some", "any", "typealias", "associatedtype", "defer", "inout", "get", "set", "willSet", "didSet",
                "nonisolated",
            ]),
            "typescript": Profile(
                keywords: [
                    "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case",
                    "default", "break",
                    "continue", "class", "extends", "implements", "interface", "type", "enum", "import", "export",
                    "from", "as", "new",
                    "this", "super", "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in",
                    "of", "void",
                    "null", "undefined", "true", "false", "public", "private", "protected", "readonly", "static",
                    "abstract", "declare",
                    "namespace", "yield", "delete", "satisfies", "keyof",
                ], backtick: true),
            "javascript": Profile(
                keywords: [
                    "const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case",
                    "default", "break",
                    "continue", "class", "extends", "import", "export", "from", "as", "new", "this", "super", "async",
                    "await", "try",
                    "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "void", "null", "undefined",
                    "true", "false", "yield",
                    "delete",
                ], backtick: true),
            "python": Profile(
                keywords: [
                    "def", "class", "return", "if", "elif", "else", "for", "while", "break", "continue", "pass",
                    "import", "from", "as",
                    "try", "except", "finally", "raise", "with", "lambda", "yield", "global", "nonlocal", "assert",
                    "del", "in", "is",
                    "not", "and", "or", "None", "True", "False", "async", "await", "self",
                ], lineComments: ["#"], block: nil),
            "go": Profile(
                keywords: [
                    "package", "import", "func", "return", "if", "else", "for", "range", "switch", "case", "default",
                    "break", "continue",
                    "go", "defer", "select", "chan", "map", "struct", "interface", "type", "var", "const", "nil",
                    "true", "false", "fallthrough",
                    "goto",
                ], backtick: true),
            "rust": Profile(keywords: [
                "fn", "let", "mut", "const", "static", "struct", "enum", "impl", "trait", "pub", "use", "mod", "crate",
                "self", "Self",
                "super", "return", "if", "else", "match", "for", "while", "loop", "break", "continue", "as", "in",
                "ref", "move", "async",
                "await", "dyn", "where", "unsafe", "true", "false", "type", "extern",
            ]),
            "bash": Profile(
                keywords: [
                    "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac", "function", "in",
                    "return", "exit",
                    "export", "local", "echo", "cd", "set", "unset", "source", "alias", "true", "false", "sudo",
                ], lineComments: ["#"], block: nil, backtick: true, calls: false),
            "json": Profile(
                keywords: ["true", "false", "null"], lineComments: [], block: nil, quotes: ["\""], calls: false),
            "yaml": Profile(
                keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], block: nil, calls: false),
            "toml": Profile(keywords: ["true", "false"], lineComments: ["#"], block: nil, calls: false),
            "sql": Profile(
                keywords: [
                    "select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set",
                    "delete", "create", "table",
                    "alter", "drop", "index", "join", "left", "right", "inner", "outer", "on", "group", "by", "order",
                    "having", "limit",
                    "offset", "as", "distinct", "union", "all", "null", "is", "in", "like", "between", "exists", "case",
                    "when", "then",
                    "else", "end", "primary", "key", "foreign", "references", "default", "unique", "with", "returning",
                    "asc", "desc",
                ], lineComments: ["--"], block: ("/*", "*/"), quotes: ["'", "\""]),
            "css": Profile(
                keywords: ["important", "inherit", "initial", "none", "auto"], lineComments: [], calls: true),
            "xml": Profile(keywords: [], lineComments: [], block: ("<!--", "-->"), calls: false),
            "java": Profile(
                keywords: c.union([
                    "extends", "implements", "interface", "final", "package", "import", "synchronized", "instanceof",
                    "throws", "abstract",
                ])),
            "kotlin": Profile(keywords: [
                "fun", "val", "var", "class", "object", "interface", "return", "if", "else", "when", "for", "while",
                "do", "in", "is",
                "as", "null", "true", "false", "import", "package", "override", "open", "data", "sealed", "suspend",
                "companion", "try",
                "catch", "finally", "throw", "this", "super", "private", "public", "internal", "protected", "by",
                "init",
            ]),
            "c": Profile(keywords: c),
            "cpp": Profile(keywords: c),
            "csharp": Profile(
                keywords: c.union([
                    "using", "namespace", "var", "string", "async", "await", "readonly", "get", "set", "internal",
                ])),
            "php": Profile(
                keywords: [
                    "function", "class", "return", "if", "else", "elseif", "foreach", "for", "while", "echo", "new",
                    "public", "private",
                    "protected", "static", "namespace", "use", "try", "catch", "throw", "null", "true", "false",
                    "array", "fn", "match",
                ], lineComments: ["//", "#"]),
            "ruby": Profile(
                keywords: [
                    "def", "end", "class", "module", "if", "elsif", "else", "unless", "case", "when", "while", "until",
                    "for", "in", "do",
                    "return", "yield", "begin", "rescue", "ensure", "raise", "require", "include", "self", "nil",
                    "true", "false", "and",
                    "or", "not", "then", "attr_accessor", "puts",
                ], lineComments: ["#"], block: nil),
        ]
    }

    // MARK: Scanner

    private struct Scanner {
        let profile: Profile
        let chars: [Character]
        var out: [SyntaxToken] = []
        var plain = ""

        init(profile: Profile, chars: [Character]) {
            self.profile = profile
            self.chars = chars
        }

        mutating func run() -> [SyntaxToken] {
            var i = 0
            while i < chars.count {
                if let end = comment(at: i) {
                    emit(.comment, chars[i..<end])
                    i = end
                } else if profile.quotes.contains(chars[i]) || (profile.backtick && chars[i] == "`") {
                    let end = string(at: i)
                    emit(.string, chars[i..<end])
                    i = end
                } else if chars[i].isNumber, !isWordPart(before: i) {
                    var end = i
                    while end < chars.count,
                        chars[end].isNumber || chars[end].isLetter || chars[end] == "." || chars[end] == "_"
                    {
                        end += 1
                    }
                    emit(.number, chars[i..<end])
                    i = end
                } else if chars[i].isLetter || chars[i] == "_" || chars[i] == "$" {
                    var end = i
                    while end < chars.count,
                        chars[end].isLetter || chars[end].isNumber || chars[end] == "_" || chars[end] == "$"
                    {
                        end += 1
                    }
                    let word = String(chars[i..<end])
                    emit(kind(of: word, endingAt: end), chars[i..<end])
                    i = end
                } else {
                    plain.append(chars[i])
                    i += 1
                }
            }
            flush()
            return out
        }

        private func isWordPart(before i: Int) -> Bool {
            guard i > 0 else { return false }
            let previous = chars[i - 1]
            return previous.isLetter || previous == "_"
        }

        private func kind(of word: String, endingAt end: Int) -> SyntaxKind {
            let lookup = profile.keywords.contains(word) ? word : word.lowercased()
            if profile.keywords.contains(word) || (profile.keywords.contains(lookup) && Self.caseFree(profile)) {
                return .keyword
            }
            if profile.calls, end < chars.count, chars[end] == "(" { return .function }
            if let first = word.first, first.isUppercase, word.count > 1 { return .type }
            return .plain
        }

        private static func caseFree(_ profile: Profile) -> Bool { profile.keywords.contains("select") }

        private func comment(at i: Int) -> Int? {
            for prefix in profile.lineComments where starts(prefix, at: i) {
                var end = i
                while end < chars.count, chars[end] != "\n" { end += 1 }
                return end
            }
            if let (open, close) = profile.block, starts(open, at: i) {
                var end = i + open.count
                while end < chars.count, !starts(close, at: end) { end += 1 }
                return min(end + close.count, chars.count)
            }
            return nil
        }

        private func string(at i: Int) -> Int {
            let quote = chars[i]
            var end = i + 1
            while end < chars.count {
                if chars[end] == "\\" {
                    end += 2
                    continue
                }
                if chars[end] == quote { return end + 1 }
                // A quote that is not closed on its line is an apostrophe or a typo, not a string to the end of the block.
                if chars[end] == "\n", quote != "`" { return i + 1 }
                end += 1
            }
            return quote == "`" ? chars.count : i + 1
        }

        private func starts(_ text: String, at i: Int) -> Bool {
            let units = Array(text)
            guard i + units.count <= chars.count else { return false }
            for (offset, unit) in units.enumerated() where chars[i + offset] != unit { return false }
            return true
        }

        private mutating func emit(_ kind: SyntaxKind, _ slice: ArraySlice<Character>) {
            if kind == .plain {
                plain.append(contentsOf: slice)
                return
            }
            flush()
            out.append(SyntaxToken(kind: kind, text: String(slice)))
        }

        private mutating func flush() {
            guard !plain.isEmpty else { return }
            out.append(SyntaxToken(kind: .plain, text: plain))
            plain = ""
        }
    }
}
