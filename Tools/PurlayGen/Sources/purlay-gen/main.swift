import Foundation
import PurlayGenCore

// purlay-gen --bundle DIR --out DIR [--kit-out DIR] [--tokens-out DIR] [--check]
//
// Reads the pinned contract bundle and writes the Swift the packages are made of. `--check` writes nothing: it fails
// when what is on disk is not exactly what would be written, in either direction.

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let check = arguments.contains("--check")
guard let bundle = option("--bundle"), let out = option("--out") else {
    FileHandle.standardError.write(Data("usage: purlay-gen --bundle DIR --out DIR [--check]\n".utf8))
    exit(2)
}

do {
    exit(
        try Command.run(
            bundle: bundle, out: out, kitOut: option("--kit-out"), tokensOut: option("--tokens-out"), check: check))
} catch {
    FileHandle.standardError.write(Data("purlay-gen: \(error)\n".utf8))
    exit(1)
}
