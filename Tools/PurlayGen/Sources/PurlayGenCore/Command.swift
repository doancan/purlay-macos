import Foundation

/// The command line's work, kept here so a test can run it.
public enum Command {
    /// Exit status: 0 when written (or when `check` found the output current), 1 otherwise.
    public static func run(bundle: String, out: String, check: Bool) throws -> Int32 {
        let manager = FileManager.default
        guard let contract = manager.contents(atPath: bundle + "/contract.json") else {
            throw GenerationError("\(bundle)/contract.json cannot be read: run scripts/contract first")
        }
        let manifest = manager.contents(atPath: bundle + "/MANIFEST.json") ?? Data()
        let source = try describe(manifest: manifest)
        let generated = try Generator.generate(contract: contract, source: source)

        if check {
            var problems: [String] = []
            let present = (try? manager.contentsOfDirectory(atPath: out)) ?? []
            for (name, text) in generated.files.sorted(by: { $0.key < $1.key }) {
                guard let existing = manager.contents(atPath: out + "/" + name) else {
                    problems.append("missing: \(name)")
                    continue
                }
                if String(decoding: existing, as: UTF8.self) != text { problems.append("out of date: \(name)") }
            }
            for name in present.sorted() where name.hasSuffix(".swift") && generated.files[name] == nil {
                problems.append("unexpected: \(name)")
            }
            for problem in problems { FileHandle.standardError.write(Data((problem + "\n").utf8)) }
            if problems.isEmpty { print("generated code is current (\(generated.files.count) files)") }
            return problems.isEmpty ? 0 : 1
        }

        try manager.createDirectory(atPath: out, withIntermediateDirectories: true)
        for name in (try? manager.contentsOfDirectory(atPath: out)) ?? [] where name.hasSuffix(".swift") {
            try manager.removeItem(atPath: out + "/" + name)
        }
        for (name, text) in generated.files {
            try Data(text.utf8).write(to: URL(fileURLWithPath: out + "/" + name))
        }
        print("wrote \(generated.files.count) files to \(out)")
        return 0
    }

    /// `server 0.1.0, contract 1`: what the output says it came from.
    static func describe(manifest: Data) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: manifest) as? JSON,
            let server = object["serverVersion"] as? String,
            let contract = object["contractVersion"] as? Int
        else { throw GenerationError("MANIFEST.json has no server and contract version") }
        return "server \(server), contract \(contract)"
    }
}
