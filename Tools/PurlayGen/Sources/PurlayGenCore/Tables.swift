import Foundation

/// The parts of the contract that are tables and not types: the constants, the routes, the close codes.
enum Tables {
    // MARK: Constants

    static func constants(_ root: JSON, header: String) throws -> String {
        guard let constants = root["constants"] as? JSON else {
            throw GenerationError("contract.json has no constants")
        }
        var members: [String] = []
        var types: [String] = []
        for key in constants.keys.sorted() {
            let name = Naming.member(key)
            let value = constants[key] as Any
            if let text = value as? String {
                members.append("    public static let \(name) = \"\(Literal.escaped(text))\"")
            } else if let number = value as? NSNumber {
                guard let integer = integral(number) else {
                    throw GenerationError("\(key): a constant number is an integer")
                }
                members.append("    public static let \(name) = \(integer)")
            } else if let list = value as? [Any] {
                let elements = try list.map { try scalar($0, key: key) }
                let allText = list.allSatisfy { $0 is String }
                members.append(
                    "    public static let \(name): [\(allText ? "String" : "Int")] = [\(elements.joined(separator: ", "))]"
                )
            } else if let object = value as? JSON {
                let typeName = Naming.type(key)
                let fields = object.keys.sorted()
                var type = "    public struct \(typeName): Sendable, Hashable {\n"
                for field in fields { type += "        public let \(Naming.member(field)): Int\n" }
                type += "    }"
                types.append(type)
                let values = try fields.map { field -> String in
                    guard let number = object[field] as? NSNumber, let integer = integral(number) else {
                        throw GenerationError("\(key).\(field): a constant in an object is an integer")
                    }
                    return "\(Emitter.unquoted(Naming.member(field))): \(integer)"
                }
                members.append("    public static let \(name) = \(typeName)(\(values.joined(separator: ", ")))")
            } else {
                throw GenerationError("\(key): a constant is a number, a text, a list of them or an object of numbers")
            }
        }
        var out = header
        out +=
            "/// What the contract fixes by name: limits, timings, patterns. A client reads them here and writes none by hand.\n"
        out += "public enum ContractConstants {\n"
        out += (members + types).joined(separator: "\n\n") + "\n}\n"

        // The error statuses and the close codes are tables of the same kind.
        guard let statuses = root["errorStatus"] as? JSON, let closes = root["closeCodes"] as? JSON else {
            throw GenerationError("contract.json has no errorStatus or closeCodes")
        }
        out += "\n/// The HTTP status each error `code` is answered with.\npublic enum ErrorStatus {\n"
        out += "    public static let all: [String: Int] = [\n"
        for code in statuses.keys.sorted() {
            guard let number = statuses[code] as? NSNumber, let integer = integral(number) else {
                throw GenerationError("errorStatus.\(code): a status is an integer")
            }
            out += "        \"\(Literal.escaped(code))\": \(integer),\n"
        }
        out += "    ]\n}\n"
        out += "\n/// The socket's application close codes.\npublic enum CloseCode {\n"
        var names: [String] = []
        for name in closes.keys.sorted() {
            guard let number = closes[name] as? NSNumber, let integer = integral(number) else {
                throw GenerationError("closeCodes.\(name): a close code is an integer")
            }
            let member = Naming.member(name)
            names.append(member)
            out += "    public static let \(member) = \(integer)\n"
        }
        out += "}\n"
        return out
    }

    private static func integral(_ number: NSNumber) -> Int? {
        number.doubleValue == number.doubleValue.rounded() ? number.intValue : nil
    }

    private static func scalar(_ value: Any, key: String) throws -> String {
        if let text = value as? String { return "\"\(Literal.escaped(text))\"" }
        if let number = value as? NSNumber, let integer = integral(number) { return String(integer) }
        throw GenerationError("\(key): a list holds integers or texts")
    }

    // MARK: Endpoints

    static func endpoints(_ root: JSON, header: String) throws -> String {
        guard let endpoints = root["endpoints"] as? [JSON] else {
            throw GenerationError("contract.json has no endpoints")
        }
        var out = header
        out += """
            /// One route of the server, as the contract lists it. A request is built from this and from nothing else.
            public struct EndpointSpec: Sendable, Hashable {
                public enum Auth: Sendable, Hashable { case session, none }
                public enum Body: Sendable, Hashable { case schema(String), octetStream }
                public enum Response: Sendable, Hashable { case empty, binary, schema(String) }

                public let id: String
                public let method: String
                public let path: String
                public let auth: Auth
                public let query: String?
                public let body: Body?
                public let responses: [Int: Response]
            }

            public enum Endpoints {
                public static let all: [EndpointSpec] = [

            """
        for endpoint in endpoints {
            guard let id = endpoint["id"] as? String, let method = endpoint["method"] as? String,
                let path = endpoint["path"] as? String, let auth = endpoint["auth"] as? String,
                let responses = endpoint["responses"] as? JSON
            else { throw GenerationError("an endpoint has no id, method, path, auth or responses") }
            guard auth == "session" || auth == "none" else { throw GenerationError("\(id): auth is \(auth)") }
            var query = "nil"
            if let schema = endpoint["query"] {
                guard let reference = (schema as? JSON)?.reference else {
                    throw GenerationError("\(id): a query is a named schema")
                }
                query = "\"\(reference)\""
            }
            var body = "nil"
            if let schema = endpoint["body"] {
                if let reference = (schema as? JSON)?.reference {
                    body = ".schema(\"\(reference)\")"
                } else if (schema as? String) == "octet-stream" {
                    body = ".octetStream"
                } else {
                    throw GenerationError("\(id): a body is a named schema or bytes")
                }
            }
            var results: [String] = []
            for status in responses.keys.sorted() {
                let value = responses[status]
                let spelled: String
                if value is NSNull {
                    spelled = ".empty"
                } else if (value as? String) == "binary" {
                    spelled = ".binary"
                } else if let reference = (value as? JSON)?.reference {
                    spelled = ".schema(\"\(reference)\")"
                } else {
                    throw GenerationError("\(id): a response is a named schema, bytes or nothing")
                }
                results.append("\(status): \(spelled)")
            }
            out += "        EndpointSpec(\n"
            out +=
                "            id: \"\(id)\", method: \"\(method)\", path: \"\(Literal.escaped(path))\", auth: .\(auth),\n"
            out += "            query: \(query), body: \(body),\n"
            out += "            responses: [\(results.joined(separator: ", "))]),\n"
        }
        out += "    ]\n}\n"
        return out
    }

    // MARK: Registry

    /// Every named type decoded and encoded again by name: how a test covers all of them without writing each out.
    static func registry(names: [String], header: String) -> String {
        var out = header
        out +=
            "/// Every schema of the contract, by name, as a function that reads JSON as its type and writes it again.\n"
        out += "public enum ContractRegistry {\n"
        out += "    public static let roundTrips: [String: @Sendable (Data) throws -> Data] = [\n"
        for name in names.sorted() {
            out +=
                "        \"\(name)\": { data in try JSONEncoder().encode(try JSONDecoder().decode(\(name).self, from: data)) },\n"
        }
        out += "    ]\n}\n"
        return out
    }
}
